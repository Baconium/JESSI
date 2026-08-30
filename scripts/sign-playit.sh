#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/dist/libplayit_agent.dylib}"
SRC_URL="${PLAYIT_URL:-https://github.com/rooootdev/playit-ios/releases/download/latest/libplayit_agent.dylib}"
FILE_NAME="libplayit_agent.dylib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unsigned="$TMP/$FILE_NAME"
signed="$TMP/$FILE_NAME"

echo "downloading unsigned playit dylib:"
echo "    $SRC_URL"
curl -fsSL -o "$unsigned" "$SRC_URL"
echo "    $(stat -f%z "$unsigned" 2>/dev/null || stat -c%s "$unsigned") bytes"

if ! command -v codesign >/dev/null 2>&1; then
  echo "install xcode cli twerp" >&2
  exit 1
fi

echo "ad-hoc signing playit..."
codesign --force --sign - "$unsigned"
mv "$unsigned" "$signed"

echo "verifying signature..."
codesign --verify --verbose=2 "$signed"
codesign -dvvv "$signed" 2>&1 | grep -Ei 'adhoc|CDHash=|Identifier=|Format=|Signature=' || true
missing=0
for sym in playit_init playit_start playit_stop playit_get_status_out playit_set_log_callback; do
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

mkdir -p "$(dirname "$OUT")"
cp "$signed" "$OUT"

echo "dylib resigned!"
