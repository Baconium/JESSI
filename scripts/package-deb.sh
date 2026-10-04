#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="JESSI"
PACKAGE_ID="com.baconmania.jessi"
ENTITLEMENTS="${JESSI_DEB_ENTITLEMENTS:-$REPO/Config/JESSI.trollstore.entitlements}"
OUT_DIR="$REPO/dist/debs"

IPA=""
SCHEMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa)
      IPA="${2:-}"
      shift 2
      ;;
    rootful|rootless|roothide)
      SCHEMES+=("$1")
      shift
      ;;
    all)
      SCHEMES+=(rootful rootless roothide)
      shift
      ;;
    -h|--help)
      echo "usage: $0 [rootful|rootless|roothide|all ...] [--ipa path/to/JESSI.ipa]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
[[ ${#SCHEMES[@]} -gt 0 ]] || SCHEMES=(rootful rootless roothide)

for tool in ldid dpkg-deb; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is missing, try: brew install $tool" >&2
    exit 1
  fi
done

if [[ -z "$IPA" ]]; then
  "$REPO/scripts/build-ipa.sh"
  IPA="$REPO/dist/$APP_NAME.ipa"
fi
if [[ ! -f "$IPA" ]]; then
  echo "ipa not found: $IPA" >&2
  exit 1
fi
IPA="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$IPA" -d "$TMP/ipa"
SRC_APP="$TMP/ipa/Payload/$APP_NAME.app"
if [[ ! -d "$SRC_APP" ]]; then
  echo "no Payload/$APP_NAME.app in $IPA" >&2
  exit 1
fi

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
SHORT_VERSION="$(plist_get "$SRC_APP" CFBundleShortVersionString)"
BUILD_VERSION="$(plist_get "$SRC_APP" CFBundleVersion)"
DEB_VERSION="$SHORT_VERSION-$BUILD_VERSION"

mkdir -p "$OUT_DIR"

for scheme in "${SCHEMES[@]}"; do
  case "$scheme" in
    rootful)  arch="iphoneos-arm";     prefix="";        compression="gzip" ;;
    rootless) arch="iphoneos-arm64";   prefix="/var/jb"; compression="xz" ;;
    roothide) arch="iphoneos-arm64e";  prefix="";        compression="xz" ;;
  esac

  stage="$TMP/stage-$scheme"
  app="$stage$prefix/Applications/$APP_NAME.app"
  mkdir -p "$(dirname "$app")" "$stage/DEBIAN"
  cp -R "$SRC_APP" "$app"

  /usr/libexec/PlistBuddy -c "Delete :JESSIJailbreakType" "$app/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :JESSIJailbreakType string $scheme" "$app/Info.plist"

  rm -rf "$app/_CodeSignature"
  ldid -S"$ENTITLEMENTS" "$app/$APP_NAME"
  for appex in "$app"/PlugIns/*.appex; do
    [[ -d "$appex" ]] || continue
    ldid -S "$appex/$(plist_get "$appex" CFBundleExecutable)"
  done

  cat > "$stage/DEBIAN/control" <<EOF
Package: $PACKAGE_ID
Name: $APP_NAME
Version: $DEB_VERSION
Architecture: $arch
Description: Run Minecraft servers natively on iOS!
Maintainer: BaconMania
Author: BaconMania
Section: Applications
Depends: firmware (>= 14.0)
Homepage: https://jessimc.dev
Icon: https://raw.githubusercontent.com/Baconium/JESSI/main/gay.png
EOF

  if [[ "$scheme" == "roothide" ]]; then
    app_path_sh='app=/Applications/JESSI.app
if command -v jbroot >/dev/null 2>&1; then app="$(jbroot "$app")"; fi'
  else
    app_path_sh="app=$prefix/Applications/JESSI.app"
  fi

  cat > "$stage/DEBIAN/postinst" <<EOF
#!/bin/sh
$app_path_sh
if command -v uicache >/dev/null 2>&1; then
  uicache -p "\$app" 2>/dev/null || uicache -a 2>/dev/null || uicache || true
fi
exit 0
EOF

  cat > "$stage/DEBIAN/prerm" <<EOF
#!/bin/sh
if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
  $app_path_sh
  if command -v uicache >/dev/null 2>&1; then
    uicache -u "\$app" || true
  fi
fi
exit 0
EOF

  chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm" "$app/$APP_NAME"
  xattr -cr "$stage" 2>/dev/null || true

  deb="$OUT_DIR/${PACKAGE_ID}_${DEB_VERSION}_${arch}.deb"
  rm -f "$deb"
  COPYFILE_DISABLE=1 dpkg-deb --root-owner-group -Z"$compression" -b "$stage" "$deb" >/dev/null
  echo "built $scheme: $deb ($(stat -f%z "$deb") bytes)"
done
