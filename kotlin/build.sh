#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

/usr/local/bin/kotlinc \
  "$ROOT_DIR/src/main/kotlin" \
  "$ROOT_DIR/src/test/kotlin" \
  -include-runtime \
  -d "$BUILD_DIR/filefs-tests.jar"

java -jar "$BUILD_DIR/filefs-tests.jar"
