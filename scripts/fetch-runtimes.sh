#!/usr/bin/env bash
set -euo pipefail

# downloads and extracts JRE's

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIMES_DIR="${PROJECT_DIR}/Runtimes"

JAVA8_URL="https://crystall1ne.dev/cdn/amethyst-ios/jre8-ios-aarch64.zip"
JAVA17_URL="https://crystall1ne.dev/cdn/amethyst-ios/jre17-ios-aarch64.zip"
JAVA21_URL="https://crystall1ne.dev/cdn/amethyst-ios/jre21-ios-aarch64.zip"

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

mkdir -p "$RUNTIMES_DIR"

echo "Downloading Java runtimes…"
curl -L -o "$workdir/jre8.zip"  "$JAVA8_URL"
curl -L -o "$workdir/jre17.zip" "$JAVA17_URL"
curl -L -o "$workdir/jre21.zip" "$JAVA21_URL"

echo "Extracting Java 8…"
unzip -q -o "$workdir/jre8.zip" -d "$workdir/jre8"
rm -rf "$RUNTIMES_DIR/java" && mkdir -p "$RUNTIMES_DIR/java"
( cd "$workdir/jre8" && tar -xf jre8-arm64-*.tar.xz -C "$RUNTIMES_DIR/java" )

echo "Extracting Java 17…"
unzip -q -o "$workdir/jre17.zip" -d "$workdir/jre17"
rm -rf "$RUNTIMES_DIR/java17" && mkdir -p "$RUNTIMES_DIR/java17"
( cd "$workdir/jre17" && tar -xf jre17-ios-arm64-*.tar.xz -C "$RUNTIMES_DIR/java17" )

echo "Extracting Java 21…"
unzip -q -o "$workdir/jre21.zip" -d "$workdir/jre21"
rm -rf "$RUNTIMES_DIR/java21" && mkdir -p "$RUNTIMES_DIR/java21"
( cd "$workdir/jre21" && tar -xf jre21-ios-arm64-*.tar.xz -C "$RUNTIMES_DIR/java21" )

echo "Done. Runtimes installed under: $RUNTIMES_DIR"
