#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid VERSION '$VERSION'." >&2
  exit 2
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "Type-checking Swift sources (catches cross-file access errors in ~20s)..."
  # -typecheck, not only -parse: sibling-file access mistakes must fail before packaging.
  swiftc -frontend -typecheck \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -Xcc -fmodule-map-file=Sources/CSpektraBridge/module.modulemap \
    -Xcc -ISources/CSpektraBridge/include \
    Sources/SpektraFilmFast/*.swift
else
  echo "Non-macOS host: syntax-parsing Swift sources. The final compile/link gate is a local macOS 26 SDK build."
  swiftc -frontend -parse Sources/SpektraFilmFast/*.swift
fi

echo "Checking SwiftPM manifest..."
swift package dump-package >/dev/null

echo "Checking shell syntax..."
bash -n BUILD_ON_MAC.command scripts/*.sh

echo "Checking known release pitfalls..."
grep -q 'swift build -c release --arch "\$ARCH" --scratch-path "\$SCRATCH" >&2' scripts/build_app.sh
grep -q '8f6651858f439a99b7202b4b8dea59e344dadf5d' scripts/bootstrap_native.sh


echo "Running production regression checks..."
python3 scripts/qa_production.py

echo "Checking source manifest coverage and hashes..."
EXPECTED_LIST="$(mktemp)"
MANIFEST_LIST="$(mktemp)"
trap 'rm -f "$EXPECTED_LIST" "$MANIFEST_LIST"' EXIT
find . -type f \
  -not -path './.build/*' \
  -not -path './dist/*' \
  -not -name 'SOURCE_MANIFEST.sha256' \
  -print | sed 's#^./##' | LC_ALL=C sort > "$EXPECTED_LIST"
awk '{ $1=""; sub(/^ +/, ""); print }' SOURCE_MANIFEST.sha256 | LC_ALL=C sort > "$MANIFEST_LIST"
if ! diff -u "$EXPECTED_LIST" "$MANIFEST_LIST"; then
  echo "SOURCE_MANIFEST.sha256 does not cover the complete source package." >&2
  exit 9
fi
shasum -a 256 -c SOURCE_MANIFEST.sha256 >/dev/null

echo "Checking bundled resources..."
shasum -a 256 Resources/AppIcon.icns Resources/SpektraFilm.metallib Resources/SpektraHanatos2025Spectra.f32 Resources/SpektraOutputGamutCompression.f32

echo "Version: $VERSION"
echo "Source checks passed. NOTE: only a local macOS 26 SDK Universal build proves final buildability."
