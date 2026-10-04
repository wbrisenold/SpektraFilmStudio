#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
VENDOR="$BUILD/vendor/spektrafilm-ofx"
GEN="$BUILD/native-generated"
NATIVE="$BUILD/native"
COMMIT="8f6651858f439a99b7202b4b8dea59e344dadf5d"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This step needs macOS because it compiles the Spektrafilm Objective-C++ native bridge that loads the bundled Metal library." >&2
  exit 2
fi

mkdir -p "$BUILD/vendor" "$GEN" "$NATIVE"

if [[ ! -d "$VENDOR/.git" ]]; then
  git clone --recursive https://github.com/chaert-s/spektrafilm-ofx.git "$VENDOR"
fi

git -C "$VENDOR" fetch --quiet origin "$COMMIT"
git -C "$VENDOR" checkout --quiet --detach "$COMMIT"
git -C "$VENDOR" submodule update --init --recursive

VENV="$BUILD/profilegen-venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/python" -m pip install "numpy>=1.26" "scipy>=1.12" "colour-science>=0.4.4,<0.5"
fi

# Generate the exact profile tables used by the native bridge at the release-adjacent commit.
SPEKTRAFILM_DATA_DIR="$VENDOR/Resources/data" \
  "$VENV/bin/python" "$VENDOR/tools/generate_profile_curves.py" \
    --output "$GEN/SpektraGeneratedProfileCurves.cpp" \
    --counts-output "$GEN/SpektraGeneratedProfileCounts.h" \
    --hanatos-output "$GEN/SpektraHanatos2025Spectra.f32.generated" \
    --output-gamut-compression-output "$GEN/SpektraOutputGamutCompression.f32.generated"

compile_arch() {
  local ARCH="$1"
  local OUT="$BUILD/native-$ARCH"
  rm -rf "$OUT" && mkdir -p "$OUT"
  local COMMON=( -std=c++17 -O3 -DNDEBUG -mmacosx-version-min=15.0 -arch "$ARCH" -I"$VENDOR/src" -I"$GEN" )
  xcrun --sdk macosx clang++ "${COMMON[@]}" -fobjc-arc -c "$VENDOR/src/SpektraAppBridge.mm" -o "$OUT/SpektraAppBridge.o"
  xcrun --sdk macosx clang++ "${COMMON[@]}" -fobjc-arc -c "$VENDOR/src/SpektraMetalRenderer.mm" -o "$OUT/SpektraMetalRenderer.o"
  xcrun --sdk macosx clang++ "${COMMON[@]}" -c "$GEN/SpektraGeneratedProfileCurves.cpp" -o "$OUT/SpektraGeneratedProfileCurves.o"
  xcrun libtool -static -o "$OUT/libSpektraFilmNativeCore.a" \
    "$OUT/SpektraAppBridge.o" "$OUT/SpektraMetalRenderer.o" "$OUT/SpektraGeneratedProfileCurves.o"
}

compile_arch arm64
compile_arch x86_64
lipo -create \
  "$BUILD/native-arm64/libSpektraFilmNativeCore.a" \
  "$BUILD/native-x86_64/libSpektraFilmNativeCore.a" \
  -output "$NATIVE/libSpektraFilmNativeCore.a"

echo "Native core ready: $NATIVE/libSpektraFilmNativeCore.a"
lipo -info "$NATIVE/libSpektraFilmNativeCore.a"
