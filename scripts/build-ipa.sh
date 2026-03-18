#!/usr/bin/env bash
set -euo pipefail

BUILD_MACOS=0
for arg in "$@"; do
  case "$arg" in
    --macos)
      BUILD_MACOS=1
      ;;
    -h|--help)
      echo "Usage: $0 [--macos]"
      echo "  --macos   Build the Mac Catalyst .app into dist/"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--macos]" >&2
      exit 2
      ;;
  esac
done

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

SDK="iphoneos"
DESTINATION="generic/platform=iOS"
PRODUCT_SUBDIR="${CONFIGURATION}-iphoneos"
if [[ "$BUILD_MACOS" == "1" ]]; then
  SDK="macosx"
  DESTINATION="platform=macOS,variant=Mac Catalyst"
  PRODUCT_SUBDIR="${CONFIGURATION}-maccatalyst"
fi

JESSI_LDID_SIGN="${JESSI_LDID_SIGN:-1}"
JESSI_LDID_ENTITLEMENTS="${JESSI_LDID_ENTITLEMENTS:-$PROJECT_DIR/Config/JESSI.trollstore.entitlements}"

# build ipa
cd "$PROJECT_DIR"

rm -rf "$DERIVED_DATA_DIR"
XCODEBUILD_LOG="$PROJECT_DIR/build/xcodebuild.log"
mkdir -p "$(dirname "$XCODEBUILD_LOG")"
rm -f "$XCODEBUILD_LOG"

run_xcodebuild() {
  local destination="$1"
  xcodebuild \
    -project "$PROJECT_DIR/JESSI.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_STYLE=Manual
}

prepare_maccatalyst_linker_path_workaround() {
  local products_dir="$DERIVED_DATA_DIR/Build/Products"
  local intermediates_dir="$DERIVED_DATA_DIR/Build/Intermediates.noindex"

  mkdir -p "$products_dir"
  if [[ ! -e "$products_dir/Release" ]]; then
    ln -s "Release-maccatalyst" "$products_dir/Release"
  fi

  local pkg
  for pkg in ZIPFoundation SWCompression BitByteData; do
    local release_dir="$intermediates_dir/${pkg}.build/Release"
    local macabi_dir="$intermediates_dir/${pkg}.build/Release-maccatalyst"
    mkdir -p "$release_dir"
    if [[ -d "$macabi_dir" && ! -e "$release_dir/${pkg}.build" ]]; then
      ln -s "../Release-maccatalyst/${pkg}.build" "$release_dir/${pkg}.build"
    fi
  done
}

set +e
if [[ "$BUILD_MACOS" == "1" ]]; then
  echo "Building with destination: $DESTINATION"
  run_xcodebuild "$DESTINATION" 2>&1 | tee "$XCODEBUILD_LOG"
  XCODEBUILD_STATUS=${PIPESTATUS[0]}
  if [[ $XCODEBUILD_STATUS -ne 0 ]] && grep -q "Build input files cannot be found" "$XCODEBUILD_LOG"; then
    echo "Retrying macOS build with linker path workaround for Swift package object products"
    prepare_maccatalyst_linker_path_workaround
    run_xcodebuild "$DESTINATION" 2>&1 | tee "$XCODEBUILD_LOG"
    XCODEBUILD_STATUS=${PIPESTATUS[0]}
  fi
else
  run_xcodebuild "$DESTINATION" 2>&1 | tee "$XCODEBUILD_LOG"
  XCODEBUILD_STATUS=${PIPESTATUS[0]}
fi
set -e

if [[ $XCODEBUILD_STATUS -ne 0 ]]; then
  echo "ERROR: xcodebuild failed (exit $XCODEBUILD_STATUS). Log: $XCODEBUILD_LOG" >&2
  echo "--- Last 200 lines ---" >&2
  tail -n 200 "$XCODEBUILD_LOG" >&2 || true
  exit "$XCODEBUILD_STATUS"
fi

APP_DIR="$DERIVED_DATA_DIR/Build/Products/${PRODUCT_SUBDIR}/${APP_NAME}.app"
if [[ ! -d "$APP_DIR" ]]; then
  echo "ERROR: Could not find built ${APP_NAME}.app at: $APP_DIR" >&2
  exit 1
fi

if [[ "$BUILD_MACOS" == "1" ]]; then
  mkdir -p "$DIST_DIR"
  DEST_APP="$DIST_DIR/${APP_NAME}.app"
  rm -rf "$DEST_APP"
  if command -v rsync >/dev/null 2>&1; then
    rsync -aL --delete "$APP_DIR/" "$DEST_APP/"
  else
    mkdir -p "$DEST_APP"
    cp -aL "$APP_DIR/." "$DEST_APP/"
  fi

  echo "Created: $DEST_APP"
  echo "macOS app built successfully"
  exit 0
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
