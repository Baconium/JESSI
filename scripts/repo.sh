#!/usr/bin/env bash
set -euo pipefail

DEBS_DIR="${1:-./debs}"
REPO_DIR="${2:-./repo}"
GPG_KEY="${GPG_KEY:-}"

for cmd in dpkg dpkg-deb dpkg-scanpackages gzip bzip2 xz awk stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: missing dependency: $cmd"
        exit 1
    fi
done

if command -v sha256sum >/dev/null 2>&1; then
    checksum() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "error: missing dependency: sha256sum or shasum"
    exit 1
fi

mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"
}

if [[ ! -d "$DEBS_DIR" ]]; then
    echo "error: directory '$DEBS_DIR' does not exist."
    exit 1
fi

mkdir -p "$REPO_DIR/debs" "$REPO_DIR/.build-state"

shopt -s nullglob
debs=("$DEBS_DIR"/*.deb)

if (( ${#debs[@]} == 0 )); then
    echo "no .deb files found."
    exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "checking ${#debs[@]} package(s)..."

for deb in "${debs[@]}"; do
    package="$(dpkg-deb -f "$deb" Package)"
    arch="$(dpkg-deb -f "$deb" Architecture)"
    source_version="$(dpkg-deb -f "$deb" Version)"
    source_hash="$(checksum "$deb")"
    source_mtime="$(mtime "$deb")"
    state_file="$REPO_DIR/.build-state/${package}_${arch}.state"

    if [[ -f "$state_file" ]]; then
        read -r previous_mtime previous_hash < "$state_file"
        if [[ "$source_hash" == "$previous_hash" ]]; then
            echo "unchanged: $package ($arch)"
            continue
        fi
        if (( source_mtime <= previous_mtime )); then
            echo "skipped: $package ($arch) has changed but is not newer"
            continue
        fi
    fi

    latest_version=""
    latest_file=""
    for published in "$REPO_DIR"/debs/*.deb; do
        [[ -f "$published" ]] || continue
        [[ "$(dpkg-deb -f "$published" Package)" == "$package" ]] || continue
        [[ "$(dpkg-deb -f "$published" Architecture)" == "$arch" ]] || continue
        published_version="$(dpkg-deb -f "$published" Version)"
        if [[ -z "$latest_version" ]] || dpkg --compare-versions "$published_version" gt "$latest_version"; then
            latest_version="$published_version"
            latest_file="$published"
        fi
    done

    if [[ -n "$latest_file" ]]; then
        if [[ "$source_hash" == "$(checksum "$latest_file")" ]]; then
            printf '%s %s\n' "$source_mtime" "$source_hash" > "$state_file"
            echo "unchanged: $package ($arch)"
            continue
        fi
        if [[ ! -f "$state_file" ]] && (( source_mtime <= $(mtime "$latest_file") )); then
            echo "skipped: $package ($arch) is not newer than the published package"
            continue
        fi
    fi

    publish_version="$source_version"
    if [[ -n "$latest_version" ]] && ! dpkg --compare-versions "$source_version" gt "$latest_version"; then
        if [[ "$latest_version" =~ ^(.+)-([0-9]+)$ ]]; then
            latest_base="${BASH_REMATCH[1]}"
            latest_revision="${BASH_REMATCH[2]}"
            source_base="$source_version"
            if [[ "$source_version" =~ ^(.+)-([0-9]+)$ ]]; then
                source_base="${BASH_REMATCH[1]}"
            fi
            if [[ "$source_base" != "$latest_base" ]]; then
                echo "skipped: $package source version $source_version is older than repo version $latest_version"
                continue
            fi
            publish_version="${latest_base}-$((10#$latest_revision + 1))"
        elif [[ "$source_version" == "$latest_version" ]]; then
            publish_version="${latest_version}-1"
        else
            echo "skipped: cannot automatically bump $package from $latest_version"
            continue
        fi
    fi

    destination="$REPO_DIR/debs/${package}_${publish_version}_${arch}.deb"
    if [[ "$publish_version" == "$source_version" ]]; then
        cp -f "$deb" "$destination"
    else
        rm -rf "$tmpdir/payload"
        dpkg-deb --raw-extract "$deb" "$tmpdir/payload"
        awk -v version="$publish_version" '
            /^Version:[[:space:]]*/ { print "Version: " version; found = 1; next }
            { print }
            END { if (!found) exit 1 }
        ' "$tmpdir/payload/DEBIAN/control" > "$tmpdir/control"
        mv "$tmpdir/control" "$tmpdir/payload/DEBIAN/control"
        dpkg-deb --root-owner-group --build "$tmpdir/payload" "$destination" >/dev/null
    fi

    printf '%s %s\n' "$source_mtime" "$source_hash" > "$state_file"
    echo "added: $package $publish_version ($arch)"
done

cd "$REPO_DIR"

echo "generating packages..."
dpkg-scanpackages -m debs /dev/null > Packages
gzip -9 -n -c Packages > Packages.gz
bzip2 -9 -c Packages > Packages.bz2
xz -9 -c Packages > Packages.xz
if command -v zstd >/dev/null 2>&1; then
    zstd -19 -q -f -c Packages > Packages.zst
else
    rm -f Packages.zst
fi

if command -v apt-ftparchive >/dev/null 2>&1; then
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="JESSI supa dupa nightly" \
        -o APT::FTPArchive::Release::Label="JESSI supa dupa nightly" \
        -o APT::FTPArchive::Release::Suite="unstable" \
        -o APT::FTPArchive::Release::Codename="unstable" \
        -o APT::FTPArchive::Release::Architectures="iphoneos-arm iphoneos-arm64 iphoneos-arm64e" \
        -o APT::FTPArchive::Release::Components="main" \
        -o APT::FTPArchive::Release::Version="1.0" \
        -o APT::FTPArchive::Release::Description="JESSI Testing Repo" \
        release . > Release

    if [[ -n "$GPG_KEY" ]]; then
        gpg --batch --yes \
            --local-user "$GPG_KEY" \
            --clearsign \
            -o InRelease Release

        gpg --batch --yes \
            --local-user "$GPG_KEY" \
            --armor --detach-sign \
            -o Release.gpg Release
    else
        rm -f InRelease Release.gpg
    fi

else
    echo "generating Release with Python..."

    python3 - <<'PY' > Release
import hashlib
from pathlib import Path
from datetime import datetime, timezone
from email.utils import format_datetime

print("Origin: JESSI supa dupa nightly")
print("Label: JESSI supa dupa nightly")
print("Suite: unstable")
print("Codename: unstable")
print("Architectures: iphoneos-arm iphoneos-arm64 iphoneos-arm64e")
print("Components: main")
print("Version: 1.0")
print("Date:", format_datetime(datetime.now(timezone.utc), usegmt=True))
print("Description: JESSI Test repo")

files = [
    name
    for name in ["Packages", "Packages.gz", "Packages.bz2", "Packages.xz", "Packages.zst"]
    if Path(name).is_file()
]

for algorithm, label in [
    ("md5", "MD5Sum"),
    ("sha256", "SHA256"),
    ("sha512", "SHA512"),
]:
    print(f"{label}:")
    for filename in files:
        data = Path(filename).read_bytes()
        digest = hashlib.new(algorithm, data).hexdigest()
        print(f" {digest} {len(data):16d} {filename}")
PY

    rm -f InRelease Release.gpg
fi

curl -o CydiaIcon.png https://baconium.dev/jessi/jessi.png

echo "repo updated successfully!"
