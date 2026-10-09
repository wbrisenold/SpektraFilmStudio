#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
bash scripts/bootstrap_native.sh
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spektrafilm-lut-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -O3 -fobjc-arc -mmacosx-version-min=15.0 -arch x86_64 \
  -I Native/src tests/density_lut_test.mm .build/native/libSpektraFilmNativeCore.a \
  -framework Foundation -framework Metal -framework MetalPerformanceShaders -framework CoreGraphics -framework ImageIO \
  -o "$TEST_DIR/density-lut-test"
SPEKTRAFILM_RESOURCE_DIR="$ROOT/Resources" "$TEST_DIR/density-lut-test" "$@"
