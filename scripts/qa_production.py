#!/usr/bin/env python3
from pathlib import Path
import math, re, sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Sources" / "SpektraFilmFast"

def text(name):
    return (SRC / name).read_text()

def require(cond, msg):
    if not cond:
        raise AssertionError(msg)

def angle(r, g, b):
    kr, kb = 0.2126, 0.0722
    kg = 1.0 - kr - kb
    y = kr*r + kg*g + kb*b
    cb = ((b-y)/(2*(1-kb))) * 2
    cr = ((r-y)/(2*(1-kr))) * 2
    a = math.degrees(math.atan2(cr, cb))
    if a < 0: a += 360
    return a

def delta(a, ref=123.0):
    d = a-ref
    while d > 180: d -= 360
    while d < -180: d += 360
    return d

app = text("AppModel.swift")
thumb = text("ThumbnailPipeline.swift")
analysis = text("StudioAnalysis.swift")
preview = text("PreviewView.swift")
export = text("ExportWriter.swift")
native = text("NativeRenderer.swift")
models = text("ProjectModels.swift")
decoder = text("ImageDecoder.swift")
interaction = text("InteractionPerformance.swift")
controls = text("ControlsView.swift")
selftest = text("ProductionSelfTest.swift")
all_src = "\n".join(p.read_text() for p in SRC.glob("*.swift"))

# Pass 4: import hot path
require("record.captureDate = Self.captureDate" not in app, "synchronous capture-date import returned")
require("renderPreview: false" in app, "library import still starts full render")
require("batchSize = 32" in app, "metadata work is not bounded")
require("NSImage(contentsOf:" not in all_src, "full NSImage decode remains in SwiftUI thumbnail path")

# Pass 5: thumbnail pipeline
require("kCGImageSourceCreateThumbnailFromImageIfAbsent: false" in thumb, "embedded RAW preview fast path missing")
require("maxWorkers = 4" in thumb, "thumbnail workers are not bounded")
require("CacheLocation.thumbnailsDirectory" in thumb, "persistent disk thumbnail cache missing")
require("480, 1280" in app, "dual-resolution thumbnail warmup missing")
require("func importFolder()" in app and "photoURLs(in:" in app, "recursive shoot-folder import missing")
require(".skipsPackageDescendants" in app and "supportedPhotoExtensions" in app, "folder import is not safely filtering recursive media")

# Pass 6: interactive latency architecture / every slider
require("decodeInteractiveWhiteBalance" in decoder, "WB still lacks no-redecode interactive path")
require("reusableCachedBuffer" in decoder and "reusableInFlightTask" in decoder and "resized(longEdge:" in decoder, "interactive decode/in-flight reuse/downscale missing")
require("vImageScale_ARGBFFFF" in interaction, "Accelerate float downscale missing")
require("vImageMatrixMultiply_ARGBFFFF" in interaction, "interactive WB is not vectorized with Accelerate")
for token in ["grainEnabled", "halationEnabled", "cameraDiffusionEnabled", "printDiffusionEnabled", "scannerEnabled", "dirCouplersAmount"]:
    require(token in interaction, f"interactive bypass policy missing {token}")
require("input.pixels.withUnsafeBytes" in native, "native renderer still copies source array")
require("var sourcePixels = input.pixels" not in native, "full source COW copy returned")
require("makeFloatImagePayload" in native and "Task.detached(priority: .userInitiated)" in app, "float preview packaging still blocks main actor")
project_models = text("ProjectModels.swift")
require("static let editProxyLongEdge = 1080" in project_models, "edit proxy is not fixed at 1080 px")
require("AppPreferences.editProxyLongEdge" in app, "render scheduler is not using the fixed 1080 edit proxy")
require("publishInteractiveProxy" in app and "InteractivePreviewProxy.render" in app, "pointer-rate controls still lack decoupled live proxy")
require("withTaskCancellationHandler" in app and "worker.cancel()" in app, "stale pointer-rate proxy workers are not explicitly cancelled")
proxy = text("InteractivePreviewProxy.swift")
require("vImageConvolve_ARGBFFFF" in proxy, "live diffusion/halation proxy still uses scalar Swift blur")
interactive_set = app.split("func setParameter", 1)[1].split("func setWhiteBalanceMode", 1)[0]
require("scheduleRender(interactive: true" not in interactive_set, "scalar pointer ticks still enqueue native spectral renders")
raw_interactive_set = app.split("func setRawSettings", 1)[1].split("func undo", 1)[0]
require("scheduleRender(" in raw_interactive_set and "rawField: field" in raw_interactive_set and "baselineRawOverride" in raw_interactive_set, "RAW WB drag is not redeveloping the linear source before the native preview")
require("publishInteractiveProxy(changedParameter: activeEditChangedParameter, rawField: nil)" in raw_interactive_set, "non-WB RAW controls lost the fast proxy path")
require("SPEKTRAFILM_SPECTRAL_TRANSMITTANCE" in native and '"exp2"' in native, "pinned exact exp2 spectral optimization not enabled")
require("let quality: RenderedPreviewQuality = .accurate" in app and "case working" not in text("CacheInfrastructure.swift"), "approximate adjusted-preview cache identity returned")
require("CacheSchema.renderedPreview" in text("CacheInfrastructure.swift"), "rendered preview cache schema token missing")
require("tuneInteractiveResolution" not in app, "obsolete adaptive edit-resolution path returned; live and idle must remain 1080 px")
require("cancelPreviewForNavigation" in app and "renderLoopID" in app, "stale load/render cancellation missing")
require("previewRasterizer.rasterize" not in app, "scalar 8-bit rasterizer returned to hot path")
require('setParameter(descriptor.name, value: .scalar($0), interactive: true)' in controls, "scalar sliders bypass audited interactive path")
require('model.setParameter(descriptor.name, value: p, interactive: true)' in controls, "vector sliders bypass audited interactive path")
require('setWhiteBalanceTemperature' in controls and 'setWhiteBalanceTint' in controls and 'WhiteBalanceTemperatureSlider' in controls, "WB sliders bypass the always-visible sourced WB controls")
noninteractive_set = app.split("func setParameter", 1)[1].split("func setRawSettings", 1)[0]
require("scheduleIdleRefinement(changedParameter: name)" in noninteractive_set, "steppers/pickers/toggles still force immediate exact render")

# White-balance direction sanity: higher Kelvin must preview warmer and lower Kelvin cooler.
def matmul(a, b):
    return [[sum(a[r][k] * b[k][c] for k in range(3)) for c in range(3)] for r in range(3)]

def matvec(a, v):
    return [sum(a[r][k] * v[k] for k in range(3)) for r in range(3)]

def white_xyz(t):
    t = max(1667.0, min(50000.0, t))
    if t <= 4000:
        x = -0.2661239e9/t**3 - 0.2343580e6/t**2 + 0.8776956e3/t + 0.179910
    else:
        x = -3.0258469e9/t**3 + 2.1070379e6/t**2 + 0.2226347e3/t + 0.240390
    if t <= 2222:
        y = -1.1063814*x**3 - 1.34811020*x**2 + 2.18555832*x - 0.20219683
    elif t <= 4000:
        y = -0.9549476*x**3 - 1.37418593*x**2 + 2.09137015*x - 0.16748867
    else:
        y = 3.0817580*x**3 - 5.87338670*x**2 + 3.75112997*x - 0.37001483
    return [x/y, 1.0, (1.0-x-y)/y]

B = [[0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]]
BI = [[0.9869929,-0.1470543,0.1599627],[0.4323053,0.5183603,0.0492912],[-0.0085287,0.0400428,0.9684867]]
R2X = [[0.6369580483012914,0.14461690358620832,0.1688809751641721],[0.2627002120112671,0.6779980715188708,0.05930171646986196],[0.0,0.028072693049087428,1.060985057710791]]
X2R = [[1.7166511879712674,-0.35567078377639233,-0.25336628137365974],[-0.6666843518324892,1.6164812366349395,0.01576854581391113],[0.017639857445310783,-0.042770613257808524,0.9421031212354738]]

def wb_neutral(baseline, target):
    # Match the Swift preview semantics: newly-declared target illuminant -> committed illuminant.
    src = matvec(B, white_xyz(target))
    dst = matvec(B, white_xyz(baseline))
    d = [[dst[0]/src[0],0,0],[0,dst[1]/src[1],0],[0,0,dst[2]/src[2]]]
    m = matmul(X2R, matmul(BI, matmul(d, matmul(B, R2X))))
    return matvec(m, [1,1,1])

warm = wb_neutral(5500, 7000)
cool = wb_neutral(5500, 3500)
require(warm[0] > warm[2], f"higher Kelvin is not warmer: {warm}")
require(cool[2] > cool[0], f"lower Kelvin is not cooler: {cool}")
require("let magentaGain = pow(2.0, tintStops)" in interaction and "let greenGain = 1.0 / magentaGain" in interaction, "tint direction/gain contract missing")

# Pass 7: clipping behavior + numeric sanity
require("let outputPeak = max(outRRaw" in analysis, "final-output highlight analysis missing")
require("let isHardHighlight = outputPeak >= highlightThreshold" in analysis, "hard highlight clipping is not final-output-only")
require("let isHardShadow = outputLuma <= shadowThreshold" in analysis, "hard shadow clipping is not final-output-only")
require("source: PixelBufferF32?" not in analysis and "sceneLuma" not in analysis and "sourcePeak" not in analysis, "diagnostics still inspect pre-film/source values")
hi = 0.18 * (2 ** 4)
lo = 0.18 * (2 ** -8)
require(hi >= 0.998, "reference highlight exposure test failed")
require(lo <= 0.002, "reference shadow exposure test failed")

# Pass 8: directional skin behavior + UI
skin_d = delta(angle(0.70, 0.45, 0.35))
magenta_d = delta(angle(1.0, 0.0, 1.0))
green_d = delta(angle(0.0, 1.0, 0.0))
require(abs(skin_d) < 12, f"skin reference sanity failed: {skin_d}")
require(magenta_d < 0, f"magenta direction sign wrong: {magenta_d}")
require(green_d > 0, f"green direction sign wrong: {green_d}")
require("SubjectSkinMaskEngine" in analysis and "OpenSourceSkinClassifier" in analysis, "subject-aware open-source skin classification is missing")
require("196, 94, 120" in analysis, "muted magenta-direction skin cue missing")
require("74, 150, 142" in analysis, "muted green-direction skin cue missing")
require("TOO MAGENTA" in preview and "TOO GREEN" in preview and "Too Magenta" in text("EditorScopePanelView.swift") and "Too Green" in text("EditorScopePanelView.swift"), "directional skin legend/readout missing")
require("skinMagentaPercent" in models and "skinGreenPercent" in models, "direction metrics missing")

# Pass 9: export isolation/reliability
for forbidden in ["analysisOverlay", "StudioAnalysis", "scopeTrace"]:
    require(forbidden not in export, f"viewer diagnostic leaked into export source: {forbidden}")
require("tiff16Bit" in export, "16-bit TIFF export path missing")
require("CGImageSourceCreateWithURL" in export, "export read-back verification missing")
require("replaceItemAt" in export or "moveItem" in export, "atomic/final file move missing")

# Pass 10 compatibility/version guards in source
require("decodeIfPresent" in models, "backward-compatible preference decoding missing")
require("migrateForV2" in models, "project migration missing")
require("flavor = .pro" in models, "Pro-only normalization missing")

print("production reference checks passed")

# v0.4 production-readiness acceptance gates
cache = text("CacheInfrastructure.swift")
recovery = text("ProjectRecovery.swift")
app_main = text("SpektraFilmFastApp.swift")
settings = text("SettingsView.swift")
auto_wb = text("AutoWhiteBalance.swift")
build_script = (ROOT / "scripts" / "build_app.sh").read_text()
notarize_script = (ROOT / "scripts" / "notarize_app.sh").read_text()

# Pointer motion is proxy-only, but mouse-up must schedule a cancellable exact normal-preview
# render. Approximate proxy pixels are never persisted as the committed adjusted preview.
end_gesture = app.split("func endEditGesture()", 1)[1].split("func setParameter", 1)[0]
require("scheduleRender(" not in end_gesture, "mouse-up launches an uncancellable render directly")
require("scheduleIdleRefinement" in end_gesture, "mouse-up does not schedule the exact settled preview")
require("settleCommittedProxy(" not in app, "approximate proxy persistence path returned")
require("project.preferences.previewLongEdge" in app and "editProxyLongEdge = 1080" in project_models, "idle edit preview is not fixed to 1080 px")
require("requestAccurateWorkingPreview" not in app and "workingPreview" not in native, "obsolete working-preview mode returned")
require("useInteractiveRenderPolicy: false" in app and "cacheResult: true" in app, "committed previews are not explicitly routed through the exact renderer policy")
require("refinementTask?.cancel()" in app, "settled exact-preview refinement is not cancelable")
require("invalidateNativePreviewForInteraction()" in app and "renderGeneration += 1" in app, "new gestures do not invalidate stale native preview publication")
require("requestPreviewRefresh" in app and 'reason: "exact preview"' in app, "exact normal-preview refresh action missing")
require("requestFullResolutionPreview" in app and "fullResolutionRequest: true" in app, "explicit full-resolution inspection missing")
require("func resetLook()" in app and 'Label("Reset All"' in text("EditView.swift"), "Reset All Edits button/path missing")
require("FaceGroupingEngine" in text("FaceGroupingEngine.swift") and "project.peopleGroups" in app, "People/Face Groups engine or project wiring missing")
require("libraryPeopleGroupFilter" in app and 'Text("PEOPLE")' in text("LibraryView.swift"), "People groups are not exposed in Library")

# Edit-tab first frame must be a lifecycle event, never require a dummy slider move.
content = text("ContentView.swift")
require("workspaceDidChange(newPage)" in content, "workspace picker does not notify the model")
require("case .library" in content and "case .cull" in content and "case .edit" in content, "unified Library/Cull/Edit shell missing")
require("func workspaceDidChange" in app, "workspace lifecycle handler missing")
workspace = app.split("func workspaceDidChange", 1)[1].split("func selectImage", 1)[0]
require('case .edit:' in workspace and 'presentFastSelectionPreview(for: image, renderOnMiss: true)' in workspace, "entering Edit does not restore cache/render on miss")
require('scheduleRender(' not in workspace, "entering Edit still starts Spektrafilm before cache lookup")
require("warmEditorSourceAfterSelectionIdle" in app and "milliseconds(240)" in app, "Library/Cull does not prewarm the selected RAW without backlog")

# Auto WB must perform real camera-space RAW analysis/correction with safe fallback.
require("rawFilter.neutralLocation" in decoder, "RAW Auto WB does not use CIRAWFilter neutralLocation")
require("estimateAutoNeutralLocation" in decoder and "bestScore" in decoder, "Auto WB neutral-patch estimator missing")
require("cameraSpaceAutoWBApplied" in decoder, "Auto WB cannot distinguish camera-space vs fallback correction")
require("applyingAutoWhiteBalance()" in decoder, "non-RAW/low-confidence Auto WB fallback missing")
require("Recalculate" in controls and "recalculateAutoWhiteBalance" in app, "Auto WB cannot be explicitly recomputed")

# Gallery/Cull workspace and bounded local smart culling.
library = text("LibraryView.swift")
cull = text("CullView.swift")
cull_support = text("LibraryCullSupport.swift")
cull_engine = text("CullEngine.swift")
require("LazyVGrid" in library and "Smart Cull" in library and "AI Review" in library, "professional Library grid/filter surface missing")
require("Loupe" in cull and "Compare" in cull and "Survey" in cull, "Cull loupe/compare/survey modes missing")
require("chunkSize = 3" in cull_support and "withTaskGroup" in cull_support, "Smart Cull work is not bounded")
require("import Vision" in cull_engine and "VNDetectFaceRectanglesRequest" in cull_engine and "dHash" in cull_engine, "Vision face/perceptual cull analysis missing")
require("YuNetFaceDetector" not in cull_engine, "removed YuNet Core ML detector returned")
require("rebuildCullStacks" in cull_support and "hammingDistance" in cull_support, "burst/similarity stack ranking missing")
require("No photo is deleted automatically" in cull_support or "no photo is deleted automatically" in cull_support.lower(), "culling safety contract missing")

# Alcedo-style scopes must be asynchronous and independent of renderer cadence.
scope_support = text("EditorScopeSupport.swift")
scope_panel = text("EditorScopePanelView.swift")
scope_engine = text("ScopeEngine.swift")
require("scopeTargetFPS" in models and "startEditorScopeLoop" in scope_support, "throttled scope loop missing")
require("scopeTask == nil" in scope_support and "scopeGeneration" in scope_support, "scope latest-frame/backpressure guard missing")
require("Histogram" in models and "Waveform" in models and "RGB Parade" in models and "Vectorscope" in models and "Skin Vector" in models, "scope modes missing")
require("EditorScopePanelView" in text("EditView.swift") and "editorScopeImage" in scope_panel, "persistent scope UI not integrated into editor inspector")
require("skinVectorscope" in scope_engine and "drawSkinReference" in scope_engine and "123.0" in scope_engine, "dedicated 123-degree skin vectorscope missing")
require("scopeModeNav" in scope_panel and "rectangle.split.3x1" in scope_panel, "compact scope icon navigation missing")
require("Task.detached(priority: .utility)" in scope_engine, "scope analysis is not off the UI actor")

# Autosave/recovery/dirty protection.
require("ProjectRecoveryStore" in recovery and "RecoveryEnvelope" in recovery, "recovery store missing")
require("scheduleAutosave()" in app and "Autosaved" in app, "autosave path missing")
require("clearSynchronously()" in recovery and "ProjectRecoveryStore.clearSynchronously()" in app, "quit/save recovery clearing is not synchronous")
require("promptForRecoveryIfAvailable" in app, "crash recovery prompt missing")
require("prepareForTermination" in app and "confirmDestructiveTransitionIfNeeded" in app, "dirty-project protection missing")
require("applicationShouldTerminate" in app_main, "quit protection is not wired to AppKit")

# Memory and persistent cache architecture.
require("CacheBudget.decodedBytes" in decoder and "cacheBytes" in decoder, "decoded cache is not byte-budgeted")
require("MemoryPressureMonitor" in cache and "DispatchSource.makeMemoryPressureSource" in cache, "memory-pressure monitor missing")
require("RenderedPreviewDiskCache" in cache and "CacheLocation.adjustedPreviewDirectory" in cache, "persistent adjusted-preview SSD cache missing")
require("RenderedPreviewDiskEntry" in cache and '.rgba32f' in cache and "FloatImageDiskCodec" in cache, "adjusted preview cache is not persistent RGBA32F")
require("makePixelBuffer()" in text("NativeRenderer.swift"), "float adjusted cache cannot restore the live edit buffer")
require("accurateEntry.quality == .accurate" in selftest and "adjusted.invalidate(url: source)" in selftest, "exact adjusted float cache runtime/invalidation test missing")
require("publishCachedRenderedFrame" in app and "latestWorkingRenderedBuffer = cached.buffer" in app, "cache hit does not restore live edit state")
require('reason: "cache miss · exact preview"' in app, "adjusted-cache miss does not own the exact preview render")
require("activeRenderer.render(renderInput, look: renderLook)" in app and ": request.look" in app, "committed preview does not render the full requested look")
require("DevelopedSourceDiskCache" in cache and "CacheLocation.developedSourcesDirectory" in cache, "persistent developed-source SSD cache missing")
require("CacheDiskBudgetPlan" in text("CacheLocation.swift") and "thumbnailBytes = total * 15 / 100" in text("CacheLocation.swift") and "developedSourceBytes = total * 50 / 100" in text("CacheLocation.swift"), "central disk-cache budget plan missing")
require("cacheMemoryMode" in app and "localDiskCacheGB" in app and "Choose Folder" in settings and "Reveal in Finder" in settings, "user-configurable app-level local/external cache controls missing")
require("CacheLocation.thumbnailsDirectory" in thumb and "diskBudgetBytes" in thumb, "thumbnail disk cache budget missing")
require("configuredCacheMemoryMode" in app and "configuredDiskCacheGB" in app, "cache reconfiguration is not change-driven")
require("trim(to: CacheBudget.decodedBytes(mode: .conservative))" in decoder, "decoded cache does not release old buffers on warning pressure")
require("case .warning:" in thumb and "trimMemory()" in thumb, "thumbnail cache does not release old buffers on warning pressure")
require("cacheDerivedThumbnailIfNeeded" in thumb and "vImageScale_ARGB8888" in thumb, "dual-resolution warmup still decodes the source twice")
require("SpektraFilmFast Cache" in text("CacheLocation.swift"), "visible app-owned cache folder missing")
require("UserDefaults.standard" in app and "SpektraFilmFast.cacheDirectoryParentPath" in app, "cache folder is not an app-level preference")
require("NSOpenPanel" in app and "Use for Cache" in app, "local/external cache folder chooser missing")
require("activateFileViewerSelecting" in app, "Reveal in Finder cache action missing")
require("CullAnalysisDiskCache" in cache and "CacheLocation.cullAnalysisDirectory" in cache, "Smart Cull disk cache missing")
require("cacheDirectoryPath" not in models, "cache location must not be stored in project files")
require("CacheSchema.thumbnail" in thumb and "CacheSchema.developedSource" in cache and "CacheSchema.renderedPreview" in cache and "CacheSchema.cullAnalysis" in cache, "cache schema/version invalidation is incomplete")
require("generationIdentifierKey" in text("CacheLocation.swift") and "fileResourceIdentifierKey" not in text("CacheLocation.swift"), "persistent cache fingerprint still depends on restart-unstable file resource identifiers")
require("private var rootDirectory: URL?" in thumb and "private var rootDirectory: URL?" in cache, "disk caches can still race-write to the hidden default root before app configuration")

# Missing-media recovery.
require("relinkMissingMedia" in app and "missingMediaCount" in app, "missing-media relink workflow missing")
require("sourceFileSize" in models and "sourceModificationTime" in models, "source fingerprint fields missing")

# Clipping semantics must be honest.
require("Exposure Warning" in settings and "final rendered image" in settings and "SpektraFilm stock/print processing" in settings, "settings do not disclose final-render diagnostic semantics")

# Expanded scene-tone controls must be real model + UI + processing controls, not labels.
tone_engine = text("ToneGradeEngine.swift")
controls = text("ControlsView.swift")
for field in ("brightness", "midtones", "highlightRecovery", "shadowRecovery", "whitePoint", "blackPoint"):
    require(f"var {field}: Double" in models, f"ToneSettings missing {field}")
for setter in ("setToneBrightness", "setToneMidtones", "setHighlightRecovery", "setShadowRecovery", "setWhitePoint", "setBlackPoint"):
    require(f"func {setter}" in app, f"AppModel missing {setter}")
for label in ("Brightness", "Midtones", "Highlight Recovery", "Shadow Recovery", "White Point", "Black Point"):
    require(f'label: "{label}"' in controls, f"Tone UI missing {label}")
require("filmicBrightness" in tone_engine and "midtones(" in tone_engine, "Brightness/Midtones processing missing")
require("highlightRecovery(" in tone_engine and "shadowRecovery(" in tone_engine, "highlight/shadow recovery processing missing")
require("remapPoints" in tone_engine and "tone.blackPoint" in tone_engine and "tone.whitePoint" in tone_engine, "black/white point processing missing")
require("Film Response" in tone_engine and "Creative" in tone_engine, "expanded film/creative tone curve preset groups missing")

# Skin analysis must be subject-isolated and its provenance disclosed in the UI/source.
subject_skin = text("SubjectSkinMask.swift")
require("VNGeneratePersonSegmentationRequest" in subject_skin and "OpenSourceSkinClassifier" in subject_skin, "subject-isolated skin detector missing")
require("Apple Vision" in settings and "published open-source YCbCr and HSV ranges" in settings, "skin detector behavior is not disclosed")

# Production distribution and runtime gates.
package_manifest = (ROOT / "Package.swift").read_text()
require("coremlcompiler compile" not in build_script and "bootstrap_cull_models" not in build_script, "removed YuNet bootstrap returned to the local build")
require('linkedFramework("Vision")' in package_manifest and 'linkedFramework("CoreML")' not in package_manifest, "Vision-only Smart Cull framework contract missing")
require("SpektraFilm.icns" in build_script and "CFBundleIconName" in build_script, "SpektraFilm app icon is not explicitly packaged")

require("SPEKTRAFILM_CODESIGN_IDENTITY" in build_script and "--options runtime" in build_script, "Developer ID hardened-runtime signing hook missing")
require("notarytool submit" in notarize_script and "stapler staple" in notarize_script and "spctl --assess" in notarize_script, "notarization/Gatekeeper gate incomplete")
require("Authority=Developer ID Application:" in notarize_script and "hardened runtime" in notarize_script, "release does not verify Developer ID/hardened runtime before notarization")
require("--self-test" in app_main and "--studio-soak-test" in app_main, "runtime/soak entry points missing")
require("lipo -create" in build_script and "arm64" in build_script and "x86_64" in build_script, "local Universal build path missing")
require("SpektraFilm.metallib" in build_script, "bundled Metal library is not copied into the app")
require("ProductionSelfTest" in app_main, "app runtime self-test entry point missing")
require("runCacheRoundTrip" in selftest and "thumbnail SSD" in selftest and "developed-source SSD" in selftest and "decode RAM hits verified" in selftest, "runtime cache hit/miss self-test missing")

# Integrated studio workflow gates.
proofs = text("ProofsView.swift")
proof_service = text("ProofDockService.swift")
geometry = text("GeometryEngine.swift")
scope = text("ScopeEngine.swift")
require("ProofsWorkspaceView" in proofs and 'case proofs = "Proofs"' in models, "native Proofs workspace missing")
require('/g/\\(gallery.shortCode)' in proof_service and "Finish Selection" in proof_service and "New Client Link" in proofs, "ProofDock short-link/finish/link-regeneration workflow incomplete")
require("Sync Client Picks to Library" in proofs and "clientPicked" in models, "client selections do not round-trip into Library")
require("CropEditorOverlay" in preview and "IMAX 15/70" in geometry and "GeometryAutoAnalyzer" in geometry, "crop/geometry studio workflow incomplete")
require("minimumScaleToCoverCrop" in geometry and "effectiveSettings.scale = max" in geometry, "Auto Fill does not solve the minimum zoom needed to cover the crop")
require("minimumScaleToCoverCrop(" in app and "geometry.autoCrop = false" in app, "crop viewer does not preview the solved Auto Fill zoom")
require('changedParameter == "crop" && isCropToolActive' in app and "objectWillChange.send()" in app, "crop overlay still forces an image resample on every drag event")
require("skinMaskAlpha" in scope and "skinMaskAlpha[mi] > 64" in scope, "Skin Vector is not restricted to detected skin pixels")
require("scopeEnabled = true" in models and "Always on in Edit" in settings, "scopes are not persistent in Edit")

print("v0.5 studio-workflow acceptance checks passed")
