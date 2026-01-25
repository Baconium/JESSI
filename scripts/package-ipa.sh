set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="jessi"
DIST_DIR="$PROJECT_DIR/dist"
PAYLOAD_DIR="$DIST_DIR/Payload"
IPA_PATH="$DIST_DIR/${APP_NAME}.ipa"

if [[ "${1:-}" == "--build" ]]; then
  (cd "$PROJECT_DIR" && make)
fi

mkdir -p "$PAYLOAD_DIR"
rm -rf "$PAYLOAD_DIR"/*
mkdir -p "$PAYLOAD_DIR"

APP_DIR="$(find "$PROJECT_DIR" -path "$PROJECT_DIR/dist" -prune -o -type d -name "${APP_NAME}.app" -print | grep -E '/\.theos/' | head -n 1 || true)"
if [[ -z "$APP_DIR" ]]; then
  APP_DIR="$(find "$PROJECT_DIR" -path "$PROJECT_DIR/dist" -prune -o -type d -name "${APP_NAME}.app" -print | head -n 1 || true)"
fi

if [[ -z "$APP_DIR" || ! -d "$APP_DIR" ]]; then
  echo "ERROR: Could not find ${APP_NAME}.app. Build first (make), then retry." >&2
  exit 1
fi

DEST_APP="$PAYLOAD_DIR/${APP_NAME}.app"

if command -v rsync >/dev/null 2>&1; then
  rsync -aL --delete "$APP_DIR"/ "$DEST_APP"/
else
  mkdir -p "$DEST_APP"
  cp -aL "$APP_DIR"/. "$DEST_APP"/
fi

rm -rf "$DEST_APP/_CodeSignature" "$DEST_APP/embedded.mobileprovision" || true

rm -f "$IPA_PATH"
(
  cd "$DIST_DIR"
  zip -qr "$IPA_PATH" "Payload"
)

echo "Created: $IPA_PATH"
