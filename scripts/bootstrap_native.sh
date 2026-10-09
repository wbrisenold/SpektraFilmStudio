#!/bin/bash
set -euo pipefail

# Builds libSpektraFilmNativeCore.a from the vendored native core in Native/.
#
# Self-contained by design: no network, no external repository, no Python. The
# native sources and the generated spectral curves are committed under Native/,
# so a fresh clone builds offline. See Native/NOTICE.md for provenance.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
NATIVE_SRC="$ROOT/Native/src"
NATIVE_GEN="$ROOT/Native/generated"
NATIVE="$BUILD/native"
OUT="$BUILD/native-x86_64"
STAMP="$NATIVE/.native-core-stamp"
CLEAN="${SPEKTRAFILM_CLEAN:-0}"

REQUIRED=(
  "$NATIVE_SRC/SpektraAppBridge.mm"
  "$NATIVE_SRC/SpektraAppBridge.h"
  "$NATIVE_SRC/SpektraMetalRenderer.mm"
  "$NATIVE_SRC/SpektraMetalRenderer.h"
  "$NATIVE_SRC/SpektraParameters.h"
  "$NATIVE_SRC/SpektraProfileCurves.h"
  "$NATIVE_SRC/SpektraRenderer.h"
  "$NATIVE_GEN/SpektraGeneratedProfileCurves.cpp"
  "$NATIVE_GEN/SpektraGeneratedProfileCounts.h"
  "$NATIVE_GEN/SpektraDensityLutShader.h"
  "$NATIVE_GEN/SpektraSpatialShader.h"
)

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This step needs macOS." >&2
  exit 2
fi

missing=()
for f in "${REQUIRED[@]}"; do
  [[ -f "$f" ]] || missing+=("${f#"$ROOT/"}")
done
if (( ${#missing[@]} )); then
  echo "Vendored native core is incomplete. Missing from this repo:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo >&2
  echo "These files are committed under Native/ so the build needs no network." >&2
  echo "Restore them with: git restore Native/" >&2
  echo "See Native/NOTICE.md for provenance and how to regenerate them." >&2
  exit 13
fi

mkdir -p "$NATIVE"

# Stamp on the vendored inputs, not a commit id: editing a vendored file or the
# generated curves must invalidate the cached library.
native_inputs_fingerprint() {
  shasum -a 256 "${REQUIRED[@]}" | shasum -a 256 | cut -d' ' -f1
}

FINGERPRINT="x86_64:$(native_inputs_fingerprint)"

native_cache_valid() {
  [[ -f "$NATIVE/libSpektraFilmNativeCore.a" && -f "$STAMP" ]] || return 1
  [[ "$(cat "$STAMP")" == "$FINGERPRINT" ]] || return 1
  local archs
  archs="$(lipo -archs "$NATIVE/libSpektraFilmNativeCore.a" 2>/dev/null || true)"
  [[ " $archs " == *" x86_64 "* ]]
}

if [[ "$CLEAN" != "1" ]] && native_cache_valid; then
  echo "Native core unchanged; using verified cached x86_64 library." >&2
  exit 0
elif [[ "$CLEAN" != "1" && -f "$NATIVE/libSpektraFilmNativeCore.a" ]]; then
  echo "Cached native core is stale or wrong-architecture; rebuilding x86_64." >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT"
COMMON=( -std=c++17 -O3 -DNDEBUG -mmacosx-version-min=15.0 -arch x86_64 -I"$NATIVE_SRC" -I"$NATIVE_GEN" )
xcrun --sdk macosx clang++ "${COMMON[@]}" -fobjc-arc -c "$NATIVE_SRC/SpektraAppBridge.mm" -o "$OUT/SpektraAppBridge.o"
xcrun --sdk macosx clang++ "${COMMON[@]}" -fobjc-arc -c "$NATIVE_SRC/SpektraMetalRenderer.mm" -o "$OUT/SpektraMetalRenderer.o"
xcrun --sdk macosx clang++ "${COMMON[@]}" -c "$NATIVE_GEN/SpektraGeneratedProfileCurves.cpp" -o "$OUT/SpektraGeneratedProfileCurves.o"
xcrun libtool -static -o "$NATIVE/libSpektraFilmNativeCore.a" \
  "$OUT/SpektraAppBridge.o" "$OUT/SpektraMetalRenderer.o" "$OUT/SpektraGeneratedProfileCurves.o"

ARCHS="$(lipo -archs "$NATIVE/libSpektraFilmNativeCore.a" 2>/dev/null || true)"
if [[ " $ARCHS " != *" x86_64 "* ]]; then
  echo "Native core architecture check failed. Expected x86_64, got: ${ARCHS:-unknown}" >&2
  exit 7
fi

printf '%s\n' "$FINGERPRINT" > "$STAMP"
echo "Native core ready: $NATIVE/libSpektraFilmNativeCore.a"
echo "Native architecture: $ARCHS"
echo "Native sources: vendored in Native/ (no network needed)"