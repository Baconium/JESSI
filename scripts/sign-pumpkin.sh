#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUMPKIN_REPO="${PUMPKIN_REPO:-$HOME/Documents/Pumpkin}"
OUT_DIR="${PUMPKIN_UPLOAD_DIR:-$REPO/pumpkin-upload}"
MANIFEST_URL="${PUMPKIN_MANIFEST_URL:-https://baconium.dev/jessi/pumpkin/versions.json}"
FILE_NAME="libpumpkin_embed.dylib"

VERSION="${1:-}"
SRC="${2:-$PUMPKIN_REPO/target/aarch64-apple-ios/release/$FILE_NAME}"

if [[ -z "$VERSION" ]]; then
  packets="$PUMPKIN_REPO/crates/pumpkin-data/src/generated/packet.rs"
  VERSION="$(grep -A1 'CURRENT_MC_VERSION' "$packets" 2>/dev/null | grep -o 'V_[0-9_]*' | head -1 | sed 's/^V_//; s/_/./g' || true)"
  if [[ -z "$VERSION" ]]; then
    echo "couldnt work out the minecraft version, pass it as the first argument" >&2
    exit 1
  fi
  echo "minecraft version from pumpkin source: $VERSION"
fi

if [[ ! -f "$SRC" ]]; then
  echo "pumpkin dylib not found: $SRC" >&2
  echo "build it with: cargo build --release --target aarch64-apple-ios -p pumpkin-embed" >&2
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "install xcode cli twerp" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
signed="$TMP/$FILE_NAME"
cp "$SRC" "$signed"
install_name_tool -id "@rpath/$FILE_NAME" "$signed"

echo "ad-hoc signing pumpkin..."
codesign --force --sign - "$signed"

echo "verifying signature..."
codesign --verify --verbose=2 "$signed"
codesign -dvvv "$signed" 2>&1 | grep -Ei 'adhoc|CDHash=|Identifier=|Format=|Signature=' || true
missing=0
for sym in pumpkin_run pumpkin_stop; do
  if nm -gU "$signed" 2>/dev/null | grep -q "T _$sym$"; then
    echo "    present  _$sym"
  else
    echo "    missing  _$sym"
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  echo "missing symbols that JESSI needs" >&2
  exit 1
fi

if ! otool -l "$signed" | grep -q LC_CODE_SIGNATURE; then
  echo "code signature doesnt seem to exist" >&2
  exit 1
fi

mkdir -p "$OUT_DIR/$VERSION"
cp "$signed" "$OUT_DIR/$VERSION/$FILE_NAME"

manifest="$OUT_DIR/versions.json"
if [[ ! -f "$manifest" ]]; then
  if curl -fsSL -o "$manifest.tmp" "$MANIFEST_URL" 2>/dev/null; then
    mv "$manifest.tmp" "$manifest"
    echo "started from the live manifest at $MANIFEST_URL"
  else
    rm -f "$manifest.tmp"
  fi
fi

python3 - "$manifest" "$VERSION" "$VERSION/$FILE_NAME" <<'PY'
import json, os, sys
path, version, url = sys.argv[1:4]
data = {"versions": []}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
entries = [e for e in data.get("versions", []) if e.get("minecraftVersion") != version]
entries.append({"minecraftVersion": version, "url": url})
def key(e):
    return [int(p) if p.isdigit() else -1 for p in e["minecraftVersion"].split(".")]
data["versions"] = sorted(entries, key=key, reverse=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

echo
echo "signed $VERSION -> $OUT_DIR/$VERSION/$FILE_NAME ($(stat -f%z "$OUT_DIR/$VERSION/$FILE_NAME") bytes)"
echo "manifest:"
cat "$manifest"
echo "upload everything in $OUT_DIR to baconium.dev/jessi/pumpkin/"
