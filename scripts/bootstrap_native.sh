#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
VENDOR="$BUILD/vendor/spektrafilm-ofx"
GEN="$BUILD/native-generated"
NATIVE="$BUILD/native"
OUT="$BUILD/native-x86_64"
COMMIT="8f6651858f439a99b7202b4b8dea59e344dadf5d"
STAMP="$NATIVE/.native-core-stamp"
CLEAN="${SPEKTRAFILM_CLEAN:-0}"
VENV="$BUILD/profilegen-venv"
PROFILEGEN_REQUIREMENTS=(
  "numpy>=1.26"
  "scipy>=1.12"
  "colour-science>=0.4.4,<0.5"
  "matplotlib>=3.8"
)

native_cache_valid() {
  [[ -f "$NATIVE/libSpektraFilmNativeCore.a" && -f "$STAMP" ]] || return 1
  [[ "$(cat "$STAMP")" == "$COMMIT:x86_64" ]] || return 1
  local archs
  archs="$(lipo -archs "$NATIVE/libSpektraFilmNativeCore.a" 2>/dev/null || true)"
  [[ " $archs " == *" x86_64 "* ]]
}

ensure_profilegen_dependencies() {
  if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
  fi

  if ! "$VENV/bin/python" - <<'PY'
import importlib.util, sys
modules = ("numpy", "scipy", "colour", "matplotlib")
missing = [name for name in modules if importlib.util.find_spec(name) is None]
if missing:
    print("Missing profilegen modules: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    "$VENV/bin/python" -m pip install --upgrade pip
    "$VENV/bin/python" -m pip install "${PROFILEGEN_REQUIREMENTS[@]}"
  fi

  "$VENV/bin/python" - <<'PY'
import numpy, scipy, colour, matplotlib
print("profilegen dependencies ready")
PY
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This step needs macOS." >&2
  exit 2
fi

mkdir -p "$BUILD/vendor" "$GEN" "$NATIVE"

if [[ "$CLEAN" != "1" ]] && native_cache_valid; then
  echo "Native core unchanged; using verified cached x86_64 library." >&2
  exit 0
elif [[ "$CLEAN" != "1" && -f "$NATIVE/libSpektraFilmNativeCore.a" ]]; then
  echo "Cached native core is stale or wrong-architecture; rebuilding x86_64." >&2
fi

if [[ ! -d "$VENDOR/.git" ]]; then
  git clone --recursive https://github.com/chaert-s/spektrafilm-ofx.git "$VENDOR"
fi

if ! git -C "$VENDOR" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  git -C "$VENDOR" fetch --quiet origin "$COMMIT"
fi
git -C "$VENDOR" checkout --quiet --detach "$COMMIT"
git -C "$VENDOR" submodule update --init --recursive

ensure_profilegen_dependencies

if [[ "$CLEAN" == "1" || ! -f "$GEN/SpektraGeneratedProfileCurves.cpp" || ! -f "$GEN/SpektraGeneratedProfileCounts.h" ]]; then
  SPEKTRAFILM_DATA_DIR="$VENDOR/Resources/data" \
    "$VENV/bin/python" "$VENDOR/tools/generate_profile_curves.py" \
      --output "$GEN/SpektraGeneratedProfileCurves.cpp" \
      --counts-output "$GEN/SpektraGeneratedProfileCounts.h" \
      --hanatos-output "$GEN/SpektraHanatos2025Spectra.f32.generated" \
      --output-gamut-compression-output "$GEN/SpektraOutputGamutCompression.f32.generated"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
COMMON=( -std=c++17 -O3 -DNDEBUG -mmacosx-version-min=15.0 -arch x86_64 -I"$VENDOR/src" -I"$GEN" )
xcrun --sdk macosx clang++ "${COMMON[@]}" -fobjc-arc -c "$VENDOR/src/SpektraAppBridge.mm" -o "$OUT/SpektraAppBridge.o"
xcrun --sdk macosx clang++ "${COMMON[@]}" -fobjc-arc -c "$VENDOR/src/SpektraMetalRenderer.mm" -o "$OUT/SpektraMetalRenderer.o"
xcrun --sdk macosx clang++ "${COMMON[@]}" -c "$GEN/SpektraGeneratedProfileCurves.cpp" -o "$OUT/SpektraGeneratedProfileCurves.o"
xcrun libtool -static -o "$NATIVE/libSpektraFilmNativeCore.a" \
  "$OUT/SpektraAppBridge.o" "$OUT/SpektraMetalRenderer.o" "$OUT/SpektraGeneratedProfileCurves.o"

ARCHS="$(lipo -archs "$NATIVE/libSpektraFilmNativeCore.a" 2>/dev/null || true)"
if [[ " $ARCHS " != *" x86_64 "* ]]; then
  echo "Native core architecture check failed. Expected x86_64, got: ${ARCHS:-unknown}" >&2
  exit 7
fi

printf '%s\n' "$COMMIT:x86_64" > "$STAMP"
echo "Native core ready: $NATIVE/libSpektraFilmNativeCore.a"
echo "Native architecture: $ARCHS"
