#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="JESSI"
CONFIGURATION="Release"
APP_NAME="JESSI"
DIST_DIR="$PROJECT_DIR/dist"
PAYLOAD_DIR="$DIST_DIR/Payload"
IPA_PATH="$DIST_DIR/${APP_NAME}.ipa"

# ensure that JRE's were downloaded
for d in "$PROJECT_DIR/Runtimes/java" "$PROJECT_DIR/Runtimes/java17" "$PROJECT_DIR/Runtimes/java21"; do
  if [[ ! -d "$d" ]]; then
    echo "ERROR: Missing Java runtimes at: $d" >&2
    echo "Run: $PROJECT_DIR/scripts/fetch-runtimes.sh" >&2
    exit 1
  fi
done

# build ipa
cd "$PROJECT_DIR"
xcodebuild \
  -project "$PROJECT_DIR/JESSI.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  >/dev/null

APP_DIR="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/${CONFIGURATION}-iphoneos/${APP_NAME}.app" -type d 2>/dev/null | head -n 1)"
if [[ -z "$APP_DIR" || ! -d "$APP_DIR" ]]; then
  echo "ERROR: Could not find built ${APP_NAME}.app in DerivedData." >&2
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

# remove mobileprovision
rm -rf "$DEST_APP/_CodeSignature" "$DEST_APP/embedded.mobileprovision" || true

mkdir -p "$DIST_DIR"
rm -f "$IPA_PATH"
(
  cd "$DIST_DIR"
  /usr/bin/zip -qr "$IPA_PATH" "Payload"
)

echo "Created: $IPA_PATH"
echo "Install with SideStore/AltStore/StikDebug or TrollStore (they will re-sign)."
