#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="JESSI"
CONFIGURATION="Release"
APP_NAME="JESSI"
DIST_DIR="$PROJECT_DIR/dist"
PAYLOAD_DIR="$DIST_DIR/Payload"
IPA_PATH="$DIST_DIR/${APP_NAME}.ipa"
DERIVED_DATA_DIR="$PROJECT_DIR/build/DerivedData"

# Note: This script does not bundle Java runtimes into the .app by default.

# build ipa
cd "$PROJECT_DIR"

rm -rf "$DERIVED_DATA_DIR"
XCODEBUILD_LOG="$PROJECT_DIR/build/xcodebuild.log"
mkdir -p "$(dirname "$XCODEBUILD_LOG")"
rm -f "$XCODEBUILD_LOG"

set +e
xcodebuild \
  -project "$PROJECT_DIR/JESSI.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  2>&1 | tee "$XCODEBUILD_LOG"
XCODEBUILD_STATUS=${PIPESTATUS[0]}
set -e

if [[ $XCODEBUILD_STATUS -ne 0 ]]; then
  echo "ERROR: xcodebuild failed (exit $XCODEBUILD_STATUS). Log: $XCODEBUILD_LOG" >&2
  echo "--- Last 200 lines ---" >&2
  tail -n 200 "$XCODEBUILD_LOG" >&2 || true
  exit "$XCODEBUILD_STATUS"
fi

APP_DIR="$DERIVED_DATA_DIR/Build/Products/${CONFIGURATION}-iphoneos/${APP_NAME}.app"
if [[ ! -d "$APP_DIR" ]]; then
  echo "ERROR: Could not find built ${APP_NAME}.app at: $APP_DIR" >&2
  exit 1
fi

mkdir -p "$PAYLOAD_DIR"
rm -rf "$PAYLOAD_DIR"/*

DEST_APP="$PAYLOAD_DIR/${APP_NAME}.app"
if command -v rsync >/dev/null 2>&1; then
  rsync -aL --delete "$APP_DIR/" "$DEST_APP/"
else
  mkdir -p "$DEST_APP"
  cp -aL "$APP_DIR/." "$DEST_APP/"
fi

# Bundle JVM dylibs (only) into the .app. The full Java runtime is downloaded at runtime.
# This keeps Mach-O dylibs within the signed app bundle so dyld/library validation succeeds.
bundle_jvm_dylibs() {
  local dest_app="$1"
  local dest_root="$dest_app/JVM"

  mkdir -p "$dest_root"

  copy_one() {
    local label="$1"
    local src_home="$2"
    local dest_home="$3"

    if [[ ! -d "$src_home" ]]; then
      echo "WARN: JVM source not found for Java ${label}: $src_home" >&2
      return 0
    fi

    mkdir -p "$dest_home/bin" "$dest_home/lib" "$dest_home/lib/jli" "$dest_home/lib/server"

    # JLI uses argv[0] as a 'java' path; it doesn't need to be executable here, but keep it sane.
    : > "$dest_home/bin/java"
    chmod +x "$dest_home/bin/java" 2>/dev/null || true

    if [[ -f "$src_home/lib/jvm.cfg" ]]; then
      cp -f "$src_home/lib/jvm.cfg" "$dest_home/lib/jvm.cfg"
    fi

    # Copy only dylibs from the runtime's lib directories.
    for rel in lib lib/jli lib/server; do
      if [[ -d "$src_home/$rel" ]]; then
        shopt -s nullglob
        for f in "$src_home/$rel"/*.dylib; do
          cp -f "$f" "$dest_home/$rel/"
        done
        shopt -u nullglob
      fi
    done
  }

  copy_one "8"  "$PROJECT_DIR/Runtimes/java"   "$dest_root/java8"
  copy_one "17" "$PROJECT_DIR/Runtimes/java17" "$dest_root/java17"
  copy_one "21" "$PROJECT_DIR/Runtimes/java21" "$dest_root/java21"
}

bundle_jvm_dylibs "$DEST_APP"

# remove mobileprovision
rm -rf "$DEST_APP/_CodeSignature" "$DEST_APP/embedded.mobileprovision" || true

mkdir -p "$DIST_DIR"
rm -f "$IPA_PATH"
(
  cd "$DIST_DIR"
  /usr/bin/zip -qr "$IPA_PATH" "Payload"
)

echo "Created: $IPA_PATH"
echo "IPA built successfully"
