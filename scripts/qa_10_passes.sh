#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass() { printf 'PASS %02d — %s\n' "$1" "$2"; }

# 1 — Swift/package structure
./scripts/verify_source.sh >/dev/null
swift package dump-package >/dev/null
pass 1 "Swift source/package validation"

# 2 — Shell/local-build structure
bash -n BUILD_ON_MAC.command scripts/*.sh
grep -q 'No GitHub repository or GitHub Actions required' BUILD_ON_MAC.command
grep -q 'SpektraFilm.metallib' scripts/build_app.sh
pass 2 "Shell syntax and local-build structure"

# 3 — Local Universal build + signed release hooks
grep -q 'swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH" >&2' scripts/build_app.sh
grep -q 'lipo -create' scripts/build_app.sh
grep -q '8f6651858f439a99b7202b4b8dea59e344dadf5d' scripts/bootstrap_native.sh
grep -q -- '--options runtime' scripts/build_app.sh
grep -q 'notarytool submit' scripts/notarize_app.sh
grep -q 'spctl --assess' scripts/notarize_app.sh
pass 3 "Local Universal build and Developer ID/notarization hooks present"

# 4 — Import/library hot path and local caches
python3 scripts/qa_production.py >/dev/null
grep -q 'renderPreview: false' Sources/SpektraFilmFast/AppModel.swift
grep -q 'func importFolder()' Sources/SpektraFilmFast/AppModel.swift
grep -q 'photoURLs(in:' Sources/SpektraFilmFast/AppModel.swift
! grep -R -q 'NSImage(contentsOf:' Sources/SpektraFilmFast
grep -q 'RenderedPreviewDiskCache' Sources/SpektraFilmFast/CacheInfrastructure.swift
grep -q 'warmEditorSourceAfterSelectionIdle' Sources/SpektraFilmFast/AppModel.swift
grep -q 'autoAnalyzeCull' Sources/SpektraFilmFast/AppModel.swift
grep -q 'writeXMPAutomatically' Sources/SpektraFilmFast/AppModel.swift
pass 4 "Nonblocking Library import, SSD cache, selected-photo prewarm"

# 5 — Byte-budgeted caches and memory pressure
grep -q 'CacheBudget.decodedBytes' Sources/SpektraFilmFast/ImageDecoder.swift
grep -q 'cacheBytes' Sources/SpektraFilmFast/ImageDecoder.swift
grep -q 'DispatchSource.makeMemoryPressureSource' Sources/SpektraFilmFast/CacheInfrastructure.swift
grep -q 'diskBudgetBytes' Sources/SpektraFilmFast/ThumbnailPipeline.swift
pass 5 "Byte-budgeted RAM caches and memory-pressure handling"

# 6 — Every-slider latency with exact settled previews
grep -q 'decodeInteractiveWhiteBalance' Sources/SpektraFilmFast/ImageDecoder.swift
grep -q 'reusableCachedBuffer' Sources/SpektraFilmFast/ImageDecoder.swift
grep -q 'vImageScale_ARGBFFFF' Sources/SpektraFilmFast/InteractionPerformance.swift
grep -q 'vImageMatrixMultiply_ARGBFFFF' Sources/SpektraFilmFast/InteractionPerformance.swift
grep -q 'vImageConvolve_ARGBFFFF' Sources/SpektraFilmFast/InteractivePreviewProxy.swift
sed -n '/func endEditGesture()/,/func setParameter/p' Sources/SpektraFilmFast/AppModel.swift | grep -q 'scheduleIdleRefinement'
! grep -q 'settleCommittedProxy' Sources/SpektraFilmFast/AppModel.swift
! grep -q 'requestAccurateWorkingPreview' Sources/SpektraFilmFast/AppModel.swift
! grep -q 'workingPreview' Sources/SpektraFilmFast/NativeRenderer.swift
grep -q 'reason: "exact preview"' Sources/SpektraFilmFast/AppModel.swift
grep -q 'refinementTask?.cancel()' Sources/SpektraFilmFast/AppModel.swift
grep -q 'workingFileLongEdge' Sources/SpektraFilmFast/ProjectModels.swift
grep -q 'filmicBrightness' Sources/SpektraFilmFast/ToneGradeEngine.swift
grep -q 'highlightRecovery' Sources/SpektraFilmFast/ToneGradeEngine.swift
grep -q 'shadowRecovery' Sources/SpektraFilmFast/ToneGradeEngine.swift
grep -q 'remapPoints' Sources/SpektraFilmFast/ToneGradeEngine.swift
pass 6 "Persistent working-file path, responsive proxy, expanded tone controls, exact settle"

# 7 — Camera-space Auto WB and Edit first-frame lifecycle
grep -q 'rawFilter.neutralLocation' Sources/SpektraFilmFast/ImageDecoder.swift
grep -q 'estimateAutoNeutralLocation' Sources/SpektraFilmFast/ImageDecoder.swift
grep -q 'recalculateAutoWhiteBalance' Sources/SpektraFilmFast/AppModel.swift
grep -q 'workspaceDidChange(newPage)' Sources/SpektraFilmFast/ContentView.swift
grep -q 'reason: "cache miss · exact preview"' Sources/SpektraFilmFast/AppModel.swift
pass 7 "Camera-space Auto WB and automatic Edit-tab first render"

# 8 — Gallery/Cull/scopes + recovery/relink
grep -q 'LibraryWorkspaceView' Sources/SpektraFilmFast/ContentView.swift
grep -q 'CullWorkspaceView' Sources/SpektraFilmFast/ContentView.swift
grep -q 'withTaskGroup' Sources/SpektraFilmFast/LibraryCullSupport.swift
grep -q 'import Vision' Sources/SpektraFilmFast/CullEngine.swift
grep -q 'VNDetectFaceRectanglesRequest' Sources/SpektraFilmFast/CullEngine.swift
! grep -q 'YuNetFaceDetector' Sources/SpektraFilmFast/CullEngine.swift
! grep -q 'coremlcompiler compile' scripts/build_app.sh
grep -q 'EditorScopePanelView' Sources/SpektraFilmFast/EditView.swift
grep -q 'ProofsWorkspaceView' Sources/SpektraFilmFast/ContentView.swift
grep -q 'Finish Selection' Sources/SpektraFilmFast/ProofDockService.swift
grep -q 'CropEditorOverlay' Sources/SpektraFilmFast/PreviewView.swift
grep -q 'IMAX 15/70' Sources/SpektraFilmFast/GeometryEngine.swift
grep -q 'skinVectorscope' Sources/SpektraFilmFast/ProjectModels.swift
grep -q 'VNGeneratePersonSegmentationRequest' Sources/SpektraFilmFast/SubjectSkinMask.swift
grep -q 'scopeTargetFPS' Sources/SpektraFilmFast/ProjectModels.swift
grep -q 'ProjectRecoveryStore' Sources/SpektraFilmFast/ProjectRecovery.swift
grep -q 'relinkMissingMedia' Sources/SpektraFilmFast/AppModel.swift
grep -q 'analyzeForCull(ids:' Sources/SpektraFilmFast/LibraryCullSupport.swift
pass 8 "Library/Cull/Proofs/Edit, subject-aware scopes, crop/geometry, recovery/relink"

# 9 — Export isolation and encoder guards
! grep -Eq 'analysisOverlay|StudioAnalysis|scopeTrace|editorScopeImage' Sources/SpektraFilmFast/ExportWriter.swift
grep -q 'tiff16Bit' Sources/SpektraFilmFast/ExportWriter.swift
grep -q 'CGImageSourceCreateWithURL' Sources/SpektraFilmFast/ExportWriter.swift
pass 9 "Full-resolution export remains diagnostics-free and verified"

# 10 — Runtime gates, migration, resources/version
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" == "0.5.2" ]]
grep -q -- '--self-test' Sources/SpektraFilmFast/SpektraFilmFastApp.swift
grep -q -- '--studio-soak-test' Sources/SpektraFilmFast/SpektraFilmFastApp.swift
grep -q 'formatVersion = 6' Sources/SpektraFilmFast/ProjectModels.swift
grep -q 'decodeIfPresent' Sources/SpektraFilmFast/ProjectModels.swift
grep -q 'static let editProxyLongEdge = 1080' Sources/SpektraFilmFast/ProjectModels.swift
grep -q 'FaceGroupingEngine' Sources/SpektraFilmFast/FaceGroupingEngine.swift
grep -q 'Label("Reset All"' Sources/SpektraFilmFast/EditView.swift
shasum -a 256 Resources/AppIcon.icns Resources/SpektraFilm.metallib Resources/SpektraHanatos2025Spectra.f32 Resources/SpektraOutputGamutCompression.f32 >/dev/null
pass 10 "Runtime/soak entry points, migration, resource integrity"

printf '\n10/10 v0.5.2 studio-workflow production-source QA passes completed.\n'
printf 'A release is only production-approved after a local macOS 26 SDK Universal build + runtime/soak + Developer ID notarization gates pass.\n'
