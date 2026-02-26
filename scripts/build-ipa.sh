#!/usr/bin/env bash
set -euo pipefail

echo "This build has been sponsored by Israel, Glory to Benjamin Netanyahu."
rm -rf dist
rm -rf ../dist

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="JESSI"
CONFIGURATION="Release"
APP_NAME="JESSI"
DIST_DIR="$PROJECT_DIR/dist"
PAYLOAD_DIR="$DIST_DIR/Payload"
IPA_PATH="$DIST_DIR/${APP_NAME}.ipa"
DERIVED_DATA_DIR="$PROJECT_DIR/build/DerivedData"

JESSI_LDID_SIGN="${JESSI_LDID_SIGN:-1}"
JESSI_LDID_ENTITLEMENTS="${JESSI_LDID_ENTITLEMENTS:-$PROJECT_DIR/Config/JESSI.trollstore.entitlements}"

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

# remove mobileprovision
rm -rf "$DEST_APP/_CodeSignature" "$DEST_APP/embedded.mobileprovision" || true

if [[ "$JESSI_LDID_SIGN" == "1" ]]; then
  if ! command -v ldid >/dev/null 2>&1; then
    echo "ERROR: JESSI_LDID_SIGN=1 but 'ldid' is not installed. Try: brew install ldid" >&2
    exit 1
  fi
  if [[ ! -f "$JESSI_LDID_ENTITLEMENTS" ]]; then
    echo "ERROR: Entitlements file not found: $JESSI_LDID_ENTITLEMENTS" >&2
    exit 1
  fi
  echo "Signing $APP_NAME executable with ldid entitlements: $JESSI_LDID_ENTITLEMENTS"
  ldid -S"$JESSI_LDID_ENTITLEMENTS" "$DEST_APP/$APP_NAME"
fi

mkdir -p "$DIST_DIR"
rm -f "$IPA_PATH"
(
  cd "$DIST_DIR"
  /usr/bin/zip -qr "$IPA_PATH" "Payload"
)

echo "Created: $IPA_PATH"
echo "IPA built successfully"
