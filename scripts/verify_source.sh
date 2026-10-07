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
    -Xcc -fmodule-map-file=Sources/CSpektraStudioCore/module.modulemap \
    -Xcc -ISources/CSpektraStudioCore/include \
    -Xcc -fmodule-map-file=Sources/SemanticMaskNative/module.modulemap \
    -Xcc -ISources/SemanticMaskNative/include \
    Sources/SpektraFilmFast/*.swift
else
  echo "Non-macOS host: syntax-parsing Swift sources. The final compile/link gate is a local macOS 26 SDK build."
  swiftc -frontend -parse Sources/SpektraFilmFast/*.swift
fi

echo "Checking SwiftPM manifest..."
swift package dump-package >/dev/null

echo "Checking shell syntax..."
bash -n BUILD_ON_MAC.command scripts/*.sh
[[ -x scripts/bootstrap_photocraft_web.sh ]] || { echo "PhotoCraft web bootstrap is missing or not executable" >&2; exit 2; }
grep -q 'bootstrap_photocraft_web.sh' scripts/build_app.sh

echo "Checking known release/build pitfalls..."

# Intel-only build contract.
grep -q 'swift build -c release --arch x86_64 --scratch-path "$SCRATCH" >&2' scripts/build_app.sh
! grep -q -- '--arch arm64' scripts/build_app.sh scripts/bootstrap_native.sh
# The vendored native core is pinned by content: these files ARE the pinned
# revision, and the revision is recorded in the attribution docs. Assert both.
grep -q '8f6651858f439a99b7202b4b8dea59e344dadf5d' Native/NOTICE.md
grep -q '8f6651858f439a99b7202b4b8dea59e344dadf5d' IMPLEMENTATION_SOURCES.md
grep -q '8f6651858f439a99b7202b4b8dea59e344dadf5d' NOTICE.md
grep -q 'SPEKTRAFILM_MIN_FREE_GB' scripts/build_app.sh
# The native core must be VENDORED in-tree, so a fresh clone builds offline. If
# any of these regress, the build silently depends on a third-party repo again.
for f in \
  Native/src/SpektraAppBridge.mm \
  Native/src/SpektraAppBridge.h \
  Native/src/SpektraMetalRenderer.mm \
  Native/src/SpektraMetalRenderer.h \
  Native/src/SpektraParameters.h \
  Native/src/SpektraProfileCurves.h \
  Native/src/SpektraRenderer.h \
  Native/generated/SpektraGeneratedProfileCurves.cpp \
  Native/generated/SpektraGeneratedProfileCounts.h \
  Native/LICENSE.txt \
  Native/NOTICE.md ; do
  [[ -f "$f" ]] || { echo "Missing vendored native core file: $f" >&2; exit 2; }
done

# No build-time fetch of the native core, and no Python profile generator:
# both would reintroduce a network/dependency failure mode.
! grep -qE 'git clone|git ls-remote|git checkout|SPEKTRAFILM_NATIVE_REPO|spektrafilm-ofx' scripts/bootstrap_native.sh \
  || { echo "bootstrap_native.sh must not fetch an external native repo" >&2; exit 2; }
! grep -qE 'python3|pip |venv|generate_profile_curves' scripts/bootstrap_native.sh \
  || { echo "bootstrap_native.sh must not need Python (generated curves are committed)" >&2; exit 2; }

# The generated curves are committed precisely so the build needs no Python.
[[ -s Native/generated/SpektraGeneratedProfileCurves.cpp ]] || { echo "generated profile curves are empty" >&2; exit 2; }

# Swift 6 matrix type-check regression: explicit arithmetic only.
MATRIX_BLOCK="$(sed -n '/static func \* (lhs: Matrix3, rhs: Matrix3)/,/func inverted()/p' Sources/SpektraFilmFast/GeometryEngine.swift)"
grep -q 'out\[8\] =' <<<"$MATRIX_BLOCK"
if grep -Eq 'reduce|for .*0\.\.<3' <<<"$MATRIX_BLOCK"; then
  echo "Matrix3 multiplication regressed to compiler-hostile nested/reduce math." >&2
  exit 12
fi

# Required symbols/properties that have previously gone missing.
grep -q 'private static func forwardMatrix(settings: GeometrySettings, width: Int, height: Int)' Sources/SpektraFilmFast/GeometryEngine.swift
grep -q 'private var latestFilmRenderedBuffer: PixelBufferF32?' Sources/SpektraFilmFast/AppModel.swift
grep -q 'private func scheduleEditorScopeUpdate(force: Bool)' Sources/SpektraFilmFast/AppModel.swift

# Swift 6 isolation / access regressions.
grep -q 'MainActor.assumeIsolated' Sources/SpektraFilmFast/SpektraFilmFastApp.swift
grep -q 'XMPService.shared' Sources/SpektraFilmFast/LibraryCullSupport.swift
! grep -q '\[xmpService\]' Sources/SpektraFilmFast/LibraryCullSupport.swift
grep -q 'String(cString: base)' Sources/SpektraFilmFast/ProofDockService.swift

# --- Swift 6 concurrency traps (each broke a release build; see AI_PITFALLS.md) ---
# 1. An `async func` does NOT inherit @MainActor inside a Task{}. It is nonisolated
#    by default, so it must be annotated explicitly or it leaves the main actor.
grep -q '@MainActor func sample(mired: Double, tint: Double)' Sources/SpektraFilmFast/AppModel.swift
# 2. `await` cannot live inside an autoclosure (`??`, map, filter, compactMap...).
#    ManagedIngest must branch explicitly instead of `expectedHash ?? (try await ...)`.
! grep -qE '\?\? *\(try await' Sources/SpektraFilmFast/ManagedIngest.swift
grep -q 'let sourceHash: String' Sources/SpektraFilmFast/ManagedIngest.swift
# 3. NSEvent is not Sendable: the local event monitor must compute a Bool inside the
#    isolated region and convert to nil/event outside it.
grep -q 'let handled: Bool = MainActor.assumeIsolated' Sources/SpektraFilmFast/SpektraFilmFastApp.swift
grep -q 'return handled ? nil : event' Sources/SpektraFilmFast/SpektraFilmFastApp.swift
# 4. A @Sendable closure must not capture a loop-mutated `var`; hoist copies first.
grep -q 'let exportSettings = job.settings' Sources/SpektraFilmFast/AppModel.swift
! grep -q 'resizedForExport(settings: job.settings)' Sources/SpektraFilmFast/AppModel.swift
# 5. Hard-clip indicators must come from the FINAL output buffer, never the
#    pre-conversion linear one (this was a real behavioural bug in v0.6.0).
#    Asserted behaviourally, not by expression text: the clip source must be
#    filled from output.pixels. Later refactors route it through
#    clippingFlags()/monitorPixels; that is fine as long as the origin
#    is the final output. Pinning the exact expression broke on such a
#    refactor even though behaviour was preserved (AI_PITFALLS.md 16).
! grep -q 'sourcePeak' Sources/SpektraFilmFast/StudioAnalysis.swift
grep -q 'monitorPixels\[p\] = monitor.0' Sources/SpektraFilmFast/StudioAnalysis.swift
grep -q 'output.pixels\[sourceIndex\]' Sources/SpektraFilmFast/StudioAnalysis.swift
grep -q 'let isHardHighlight' Sources/SpektraFilmFast/StudioAnalysis.swift
grep -q 'let isHardShadow' Sources/SpektraFilmFast/StudioAnalysis.swift

echo "Running production regression checks..."
python3 scripts/qa_production.py

echo "Checking source manifest coverage and hashes..."
EXPECTED_LIST="$(mktemp)"
MANIFEST_LIST="$(mktemp)"
trap 'rm -f "$EXPECTED_LIST" "$MANIFEST_LIST"' EXIT
find . -type f \
  -not -path './.build/*' \
  -not -path './dist/*' \
  -not -path './.git/*' \
  -not -path './Vendor/*' \
  -not -path './Resources/AIModels/*' \
  -not -name 'SOURCE_MANIFEST.sha256' \
  -not -name '.DS_Store' \
  -not -path './.batch-edit-backup-*' \
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
echo "Source checks passed. NOTE: only a local macOS 26 SDK Intel x86_64 build proves final buildability."
