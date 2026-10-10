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
# Loaded up front: pass 7 asserts against it, so it must not be defined later in
# the file or the suite dies with NameError instead of reporting a real failure.
skin_ref = text("SkinToneReference.swift")
all_src = "\n".join(p.read_text() for p in SRC.glob("*.swift"))

# Pass 4: import hot path
require("record.captureDate = Self.captureDate" not in app, "synchronous capture-date import returned")
require("renderPreview: false" in all_src, "Library/Cull decode-free selection (renderPreview:false) disappeared")
require("project.selectedImageID = first.id" in app and "selectImage(first.id" not in app,
        "library import still wakes preview/decode/render")
require("Library/Cull selection must stay decode-free" in app, "decode-free library selection branch missing")
require("keep the renderer asleep until Edit is explicitly entered" in app,
        "project open must land in Library with the renderer asleep")
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
for token in ["fastSpatial", "grainModel", "grainSublayersEnabled", "dirCouplersDiffusionUm", "dirCouplersDiffusionTailUm"]:
    require(token in interaction, f"interactive bypass policy missing {token}")
require('setScalar("dirCouplersAmount", 0' not in interaction, "interactive DIR chemistry must remain enabled")
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
require('reason: "live working render"' not in app and 'reason: "live white balance"' not in app and 'reason: "live density"' not in app, "continuous edit path still invokes native spectral renderer")
raw_interactive_set = app.split("func setRawSettings", 1)[1].split("func undo", 1)[0]
require('reason: "live white balance"' not in raw_interactive_set, "RAW WB pointer ticks still enqueue native spectral renders")
require("publishInteractiveProxy(changedParameter: activeEditChangedParameter, rawField: field)" in raw_interactive_set, "RAW WB drag lost the display-only proxy path")
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

# Pass 7: darktable-derived final-output clipping behavior + numeric sanity
require("canonicalLinearSRGBUnclamped" in skin_ref, "unclamped final-output canonical RGB path missing")
require("private static func clippingFlags" in analysis, "darktable-style clipping classifier missing")
require("case .fullGamut" in analysis and "case .anyRGB" in analysis and "case .luminance" in analysis and "case .saturation" in analysis, "clipping preview modes incomplete")
require("255, 0, 0, 255" in analysis and "0, 0, 255, 255" in analysis, "darktable red/blue hard clipping look missing")
require("monitorPixels" in analysis and "DisplayMonitorSignal.rgb" in analysis, "hard clipping is not using the final display-referred output signal")
require("source: PixelBufferF32?" not in analysis and "sceneLuma" not in analysis and "sourcePeak" not in analysis, "diagnostics still inspect pre-film/source values")
require("ClippingPreviewMode" in models and "fullGamut" in models, "full-gamut clipping preference missing")
hi = 0.9999
lo = 2 ** -12.69
require(abs(hi - 0.9999) < 1e-12, "darktable current upper default sanity failed")
require(abs(lo - 0.00015133150634020836) < 1e-12, "darktable -12.69 EV lower reference failed")

# Pass 8: directional skin behavior + UI
skin_d = delta(angle(0.70, 0.45, 0.35))
magenta_d = delta(angle(1.0, 0.0, 1.0))
green_d = delta(angle(0.0, 1.0, 0.0))
require(abs(skin_d) < 12, f"skin reference sanity failed: {skin_d}")
require(magenta_d < 0, f"magenta direction sign wrong: {magenta_d}")
require(green_d > 0, f"green direction sign wrong: {green_d}")
require("SubjectSkinMaskEngine" in analysis and "OpenSourceSkinClassifier" in analysis, "subject-aware open-source skin classification is missing")
require("refineSkinMask" in analysis and "soft-union" in analysis, "spatially pooled skin-mask cleanup missing")
require("rr = 44; gg = 214; bb = 174" in analysis, "too-green cyan/green skin overlay missing")
require("rr = 229; gg = 65; bb = 177" in analysis, "too-magenta skin overlay missing")
require("rr = 238; gg = 184; bb = 72" in analysis, "on-target gold skin overlay missing")
require("TOO MAGENTA" in preview and "TOO GREEN" in preview and "ON TARGET" in preview and "Too Magenta" in text("EditorScopePanelView.swift") and "Too Green" in text("EditorScopePanelView.swift"), "directional skin legend/readout missing")
require("contentMode: .fit" in text("EditView.swift"), "Edit filmstrip thumbnails are still crop/fill")
require('Picker("Left browser"' in text("EditView.swift") and "LazyVGrid" in text("EditView.swift"), "Edit Photos tab in left sidebar missing")
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
lv = text("LibraryView.swift")
require("libraryPeopleGroupFilter" in app and ('Text("People")' in lv or 'Text("PEOPLE")' in lv), "People groups are not exposed in Library")

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
require(all("case " + mode in cull for mode in ("loupe", "compare", "survey")), "Cull single/compare/overview modes missing")
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
edit_view = text("EditView.swift")
require("StudioFloatingScopes(model: model" in edit_view and
        "EditorScopePanelView(model: model" in text("StudioFloatingScopes.swift") and
        "clippingEnabled" in scope_panel and "skinCheckEnabled" in scope_panel and
        "editorScopeImage" in scope_panel,
        "floating contextual scopes lost or canonical scope readout missing")
require("sidebarActuallyVisible" not in edit_view and "model.isPresetSidebarVisible" in edit_view,
        "showing scopes must not auto-hide Photos/Presets sidebar")
require("skinVectorscope" in scope_engine and "drawSkinReference" in scope_engine, "dedicated skin vectorscope missing")
require(scope_engine.count("SkinToneReference.referenceAngleDegrees") >= 1, "skin vectorscope does not use the shared derived reference angle")
require("static let referenceAngleDegrees" in text("SkinToneReference.swift"), "skin reference angle is not derived from a single shared constant")
require("Picker(\"Scope\"" in scope_panel and "rectangle.split.3x1" in scope_panel and "contextMenu" in scope_panel, "scope mode must be selectable (context menu) rather than a permanent strip")
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
require('SpektraFilePanel.chooseFolder(title: "Choose Cache Folder")' in app and "setCacheFolder(parent)" in app, "local/external cache folder chooser missing")
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

# Regression gates for v0.6.8 live-render/mask/export failures.
require("applyingHostAndFilmGrade(tone: request.look.tone" in app, "settled preview drops RAW Develop host tone")
require("applyingHostGrade(tone: nil" not in app, "settled preview still discards RAW Develop host tone")
proxy_block = app.split("private func publishInteractiveProxy",1)[1].split("private func schedulePreviewRenderAfterIdle",1)[0]
require("requestEditorScopeUpdate()" in proxy_block, "false color/scopes do not follow the live slider proxy")
require("activeLocalGradeID" in app and "publishLocalGradePreview" in app, "selected-mask local edit target missing")
require("centerX" in models and "centerY" in models and "LensCharacterOverlay" in preview, "Lens Character center overlay missing")
export_preview = text("StudioExportPreview.swift")
require("settings.resizeMode" in export_preview and "settings.resizeWidth" in export_preview and "settings.resizeHeight" in export_preview,
        "export preview refresh ignores sizing/crop selections")
require("presetThumbnail(" not in text("PresetBrowserView.swift"), "preset browser returned to stale thumbnail grid")
tone_grade = text("ToneGradeEngine.swift")
proxy_src = text("InteractivePreviewProxy.swift")
edit_view = text("EditView.swift")
require("enum MEDesatchMath" in tone_grade and "coneSaturationMagnitude" in tone_grade,
        "ME deSatch cone-coordinate density math missing")
require("PrimeraDensityMath" not in tone_grade, "old Primera density engine still present")
require("applyingMEDesatchTransfer" in proxy_src, "interactive density still uses an approximation")
require("range: -1...0" in controls and "Global deSatch" in controls,
        "ME deSatch slider domain/UI missing")
require("Preserve Luminance" not in controls, "non-ME preserve-luminance UI returned")
require('["filmExposureEv", "autoExposure", "autoExposureMethod"].contains' not in controls,
        "original Film Exposure/Auto Exposure controls are still filtered out")
require('Button("Export This Photo…")' in edit_view and "func exportImage(_ id: UUID)" in app,
        "single-photo filmstrip export missing")
require(not (SRC / "SemanticMaskPanel.swift").exists(), "dead duplicate SemanticMaskPanel returned")
cargo = (ROOT / "Rust" / "SpektraStudioCore" / "Cargo.toml").read_text()
require(cargo.count("lightcraft-") == 1 and "lightcraft-develop" in cargo,
        "unreferenced direct LightCraft crates returned to unified core")
bootstrap = (ROOT / "scripts" / "bootstrap_unified_rust_core.sh").read_text()
require("Using cached pinned LightCraft checkout" in bootstrap,
        "LightCraft bootstrap still fetches the already-correct pin every build")
build_app = (ROOT / "scripts" / "build_app.sh").read_text()
require('rm -rf "$ROOT/dist"' not in build_app, "release build still deletes the entire dist directory")
require("Licenses/ME_Desatch" in build_app, "ME deSatch attribution is not packaged")
require("SpektraFilmStudio-GPL-3.0.txt" in build_app, "root GPL license is not packaged")
require((ROOT / "THIRD_PARTY" / "ME_Desatch" / "NOTICE").exists(),
        "ME deSatch source attribution missing")

# iCloud Lightroom migration + export UX/stability.
cloud = text("SpektraCloudLibrary.swift")
cloud_support = text("CloudLibrarySupport.swift")
quick_export = text("QuickExportSheet.swift")
edit_view = text("EditView.swift")
export_view = text("ExportView.swift")
cull_view = text("CullView.swift")
export_job = text("ExportJob.swift")
require("CloudLibraryOperation" in cloud and "CloudLibrarySnapshot" in cloud,
        "immutable iCloud journal/snapshot architecture missing")
require("importLightroomClassic" in cloud and "LightroomDevelopMapper" in text("LightroomDevelopMapper.swift"),
        "Lightroom-to-iCloud migration missing")
require("cloudRelativePath" in models and "cloudPreviewRelativePath" in models,
        "portable cloud paths/smart previews missing")
require("var originalByPath: [String: String]" in cloud and
        "previewRelativePath(photoID: recordID)" in cloud and
        "[String: (original: String, preview: String?)]" not in cloud,
        "virtual copies can still share a mutable cloud preview")
require("scheduleCloudPublish()" in app and "restoreCloudLibraryIfPossible" in app,
        "project edits are not wired to cloud sync")
require("materializeIfNeeded(url)" in app,
        "full-resolution export does not materialize iCloud placeholders")
require("postProcessWorkerCount = 2" in export_job and
        "exportPostprocessWorkerLimit" in app and
        "estimatedBytes >= 640 * mib" in app,
        "full-resolution export lacks the large-frame one-worker memory gate")
require("pixels <= 12_000_000" in app and "UInt64(pixels) * 80" in app,
        "large-image decode-ahead can still overcommit memory")
require("var working = MaskedLocalGradeEngine.apply" in app and "working = LensCharacterEngine.apply" in app,
        "export keeps multiple full-resolution intermediates live")
require("QuickExportSheet" in edit_view and 'Button("Export This Photo…")' in edit_view,
        "compact single-photo export flow missing")
require("private var exportActions" in export_view and "actionFooter" in export_view and
        "model.isExporting || model.activeExportJob != nil" in export_view,
        "export action must live in the header and the footer must collapse when idle")
require("Crop Photo" in export_view and "PreviewView(model: model)" in export_view,
        "Export does not reuse Edit crop workflow")
require("selectLibraryImage(image.id)" in export_view and "selectLibraryImage(image.id)" in cull_view,
        "focused photo does not remain continuous across pages")
require("CloudLibraryPanel(model: model)" in text("LibraryView.swift"),
        "iCloud controls missing from Library")

# Expanded scene-tone controls must be real model + UI + processing controls, not labels.
tone_engine = text("ToneGradeEngine.swift")
controls = text("ControlsView.swift")
for field in ("brightness", "midtones", "highlightRecovery", "shadowRecovery", "whitePoint", "blackPoint"):
    require(f"var {field}: Double" in models, f"ToneSettings missing {field}")
for setter in ("setToneBrightness", "setToneMidtones", "setHighlightRecovery", "setShadowRecovery", "setWhitePoint", "setBlackPoint"):
    require(f"func {setter}" in app, f"AppModel missing {setter}")
for label in ("Exposure", "Global Tone", "Shadow Boost", "Highlight Headroom",
              "Contrast", "Midtones", "Highlights", "Highlight Recovery",
              "Shadows", "Shadow Recovery", "Whites", "Blacks"):
    require(f'"{label}"' in controls, f"RAW Develop UI missing {label}")
require("func setRawDevelopExposure" in app and "func setRawDevelopCurvePoints" in app,
        "RAW Develop controls are not wired to the model")
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
require("--arch x86_64" in build_script and "--arch arm64" not in build_script and "lipo -create" not in build_script, "local Intel x86_64 build path missing or arm64 was reintroduced")
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
require("scopeEnabled = true" in models and "StudioFloatingScopes(model: model" in edit_view and "Floating contextual monitor" in settings, "Edit scopes placement control or truthful settings description missing")

print("v0.5 studio-workflow acceptance checks passed")


# Skin diagnostics / As-Shot Skin WB production guards. (skin_ref loaded above.)
require("ScopeWalker" in skin_ref and "referenceAngleDegrees" in skin_ref, "open-source calibrated skin-line reference missing")
require("canonicalDisplayRGB" in skin_ref and "outputRoleIndex" in skin_ref, "skin diagnostics are not colorspace/output-role aware")
require("displayR:" in text("SubjectSkinMask.swift") and "displayEncode(linearR)" not in text("SubjectSkinMask.swift"), "skin classifier still double-gamma encodes renderer output")
require("func autoWhiteBalanceToSkin()" in app and "whiteBalanceMode = .asShot" in app, "As-Shot Skin WB solver missing")
require("Skin WB exact preview" in app and "skinWhiteBalanceGeneration" in app, "Skin WB is not cancellable/exact")
require('Label("WB to Skin"' in controls, "WB to Skin button missing from RAW controls")
require("CORRECT → push tint toward GREEN" in scope_panel and "arrow.right.circle" in scope_panel, "skin correction direction UI missing")
require("if interactive { return }" in app and "Diagnostics update after the exact render settles" in app, "diagnostics still report transient proxy measurements")


# v0.6 production hardening guards
export_job = text("ExportJob.swift")
managed_ingest = text("ManagedIngest.swift")
export_view = text("ExportView.swift")
require("self?.handleMemoryPressure(level)" in app and "full-resolution/transient buffers released" in app, "memory pressure is still disconnected")
require("Snapshot only after the debounce wins" in app and "let snapshot = project" in app, "autosave still snapshots before debounce")
require("The old path copied the entire" in app and "var updated = project" not in app.split("startBackgroundImportHydration",1)[1].split("Workspace transitions",1)[0], "import hydration still copies/rescans the whole project")
require("projectGeneration += 1" in app and "peopleGroupingTask" in app and "proofGenerationTask" in app, "project-scoped task cancellation missing")
require("Import time is never" in cull_support and "seconds <= 3.0 && hashDistance <= 18" in cull_support, "burst grouping can still use import time/hash-only chaining")
require("syncActiveLookToHighlighted" in cull_support and 'Menu("Sync Active Look")' in library, "batch look sync missing")
require("SHA256" in managed_ingest and "primary + backup verified" in managed_ingest and "active-ingest.json" in managed_ingest, "verified resumable ingest missing")
require('Button("Verified Card Ingest…"' in library and 'Button("Resume Ingest"' in library, "managed ingest UI missing")
require("active-export.json" in export_job and "normalizeAfterInterruptedLaunch" in export_job, "crash-resumable export journal missing")
require('expanded += "_\\(sequenceText)"' in export_job, "static export templates do not auto-number")
require("replaceItemAt" not in text("ExportWriter.swift") and "destinationExists" in text("ExportWriter.swift"), "export writer can still overwrite existing files")
require("func stopExport()" in app and "exportTask?.cancel()" in app and 'Stop Export' in export_view, "hard Stop Export missing")
require("ExportJobPlanner.previewNames" in app and "Preflight" in export_view, "export filename preflight missing")
# Pass 19: 2026 export / WB / cull architecture.
scope_panel_v3 = text("EditorScopePanelView.swift")
export_view_v3 = text("ExportView.swift")
cull_view_v3 = text("CullView.swift")
audit_v3 = (ROOT / "docs/DEVELOPMENT_HISTORY.md").read_text()

require(
    "cameraSpaceWhiteBalanceApplied" in decoder,
    "settled RAW WB is not owned by the CIRAWFilter path"
)
require(
    "exactLinear = try await decoder.decode" in app,
    "Skin WB still chooses its correction from the interactive RGB proxy"
)
require(
    "FINAL refined mask" in analysis and
    "skinDensity = [UInt32](repeating: 0" in analysis,
    "skin overlay and vectorscope are not rebuilt from the same refined mask"
)
require(
    "Mixed Green / Magenta" in scope_panel_v3,
    "mixed green/magenta skin state is missing"
)
require(
    "availableMemoryBytes()" in app and
    "45_000_000" not in app,
    "export decode-ahead still uses an MP ceiling instead of a byte budget"
)
require(
    "PendingExportPostprocess" in app and
    "settlePostprocess" in app and
    "makePostprocessHeadroom" in app and
    "exportPostprocessBudgetBytes" in app,
    "Alcedo-style bounded post-render export pool is missing"
)
require(
    "postProcessWorkerCount = 2" in export_job and
    "exportPostprocessWorkerLimit" in app and
    "estimatedBytes >= 640 * mib" in app and
    "actor ExportEngine" not in export and
    "struct ExportEngine: Sendable" in export,
    "export post-process concurrency is not memory-adaptive"
)
require(
    "Stage 1 boundary: the serialized render lane ENDS here." in app,
    "geometry/resize did not move behind the exact-render boundary"
)
require(
    "vDSP_vfixru8" in native and
    "vDSP_vfixru16" in native,
    "Accelerate export quantization is missing"
)
require(
    "CGImageSourceCreateImageAtIndex(source, 0, nil)" not in export,
    "16-bit TIFF verification still re-decodes full image pixels"
)
require(
    "ExportColorMode" in models and
    "sRGB · Web / Phone" in models,
    "explicit sRGB delivery mode is missing"
)
require(
    "CullNavigationScope" in cull_view_v3 and
    "case highlighted" in cull_view_v3,
    "selection-aware Cull workflow is missing"
)
require(
    "ExportSourceFilter" in export_view_v3 and
    "Build Set" in export_view_v3,
    "redesigned export-set browser is missing"
)
require(
    "Intel x86_64 only" in audit_v3,
    "architecture audit no longer records the Intel-only contract"
)

# Redlamp layout parity (PanelMetrics): every overlay panel uses the same metric
# constants rather than per-page width guesses.
_redlamp_layout = text("StudioUI.swift")
require("editorInspectorWidth: CGFloat = 316" in _redlamp_layout and "presetSidebarWidth: CGFloat = 300" in _redlamp_layout,
        "panel widths must preserve the right inspector and make the Photos/Presets sidebar readable")
for _page in ("LibraryView.swift", "CullView.swift", "ProofsView.swift", "ExportView.swift"):
    _t = text(_page)
    require(".frame(minWidth:" not in _t or "StudioLayout." in _t,
            f"{_page} hardcodes a panel width instead of using StudioLayout (Redlamp PanelMetrics)")
# Export must keep Redlamp's ExportSheetSections grouping (Location / File / Size /
# Metadata). Six bespoke cards made it read like a different product entirely.
require("StudioExportSectionLayout(" in export_view and
        all(f'section("{name}")' in text("StudioExportSectionLayout.swift")
            for name in ("Location", "File", "Size", "Metadata")),
        "Redlamp modular export Location/File/Size/Metadata sections lost")
require('section("Destination"' not in export_view and 'section("File Format"' not in export_view,
        "Export reverted to bespoke grouping")
# The requested layout is Photos / Presets tabs in the left browser; the bottom
# floating filmstrip must stay removed. Scopes belong to a resizable center dock.
_require = {
    'Text("Presets").tag("presets")' in edit_view,
    'Text("Photos").tag("photos")' in edit_view,
    'LazyVGrid(columns:' in edit_view,
    'ScrollView(.horizontal)' not in edit_view,
    'StudioFloatingScopes(model: model' in edit_view,
    'DragGesture(minimumDistance: 3)' in text("StudioFloatingScopes.swift"),
    'let width = 768' in scope_engine,
    'let size = 448' in scope_engine,
}
require(all(_require), "tabbed Photos browser or large resizable scopes dock regressed")
# Redlamp visual parity: the neutral white-alpha palette, the Typography specs
# (including 0.6pt section tracking), the Metrics row sizes, and Redlamp's own
# slider track. System label colours and system sliders are what made our rail
# read as a different product even after the structure matched.
_ui = text("StudioUI.swift")
require("sectionTracking: CGFloat = 0.6" in _ui, "StudioType.section must carry Redlamp's 0.6pt tracking")
require("labelWidth: CGFloat = 76" in _ui and "rowHeight: CGFloat = 20" in _ui
        and "panelSymbolSlot: CGFloat = 16" in _ui and "thumbSize: CGFloat = 11" in _ui,
        "StudioType metrics must match Redlamp Metrics.swift")
require("static let secondaryLabel = white(0.45)" in _ui and "static let well" not in _ui
        and "static let tertiaryLabel = white(0.28)" in _ui,
        "StudioPalette must use Redlamp's explicit white-alpha ramp, not system label colours")
require("Color.primary.opacity" not in _ui and "Color.secondary\n" not in _ui,
        "StudioPalette still uses system colours; Redlamp editing surfaces are neutral")
require("StudioSliderTrack(" in controls and "struct StudioSliderTrack" in _ui,
        "preserve Redlamp slider behavior and appearance")

print("PRODUCTION STATIC QA PASS")

# User-facing workflow regressions from the Redlamp design audit.
require(export_view.count("model.chooseExportDestination()") == 1, "Export must have one destination chooser")
require('Picker("RAW workflow"' in controls and 'Picker("Film workflow"' in controls and "DisclosureGroup" not in controls, "RAW and Film controls must preserve tabs, without accordions")
# Regression guard: each RAW tab must render exactly one section. Rendering all four
# on every tab and expanding a different one is what "all sections in every tab" means.
require('switch openAdjustment ?? "tone"' in controls, "RAW tabs must filter sections instead of rendering all of them")
require(controls.count('inspectorSection("') >= 5, "expected the per-section helpers to still exist")
require("requestedInitialSource = true\n            chooseSource()" in text("StudioImportWizard.swift"), "guided source chooser must open immediately")
require('Button("Back")' not in text("CloudSetupWizard.swift"), "cloud setup returned to sequential pages")

require("SAM2TinySegmenter()" in text("SemanticMaskEngine.swift"), "SAM 2.1 object selection missing")
require("sf_semantic_point_run(" not in text("SemanticMaskEngine.swift"), "legacy MobileSAM selection returned")
require("VNGenerateForegroundInstanceMaskRequest()" in text("RedlampVisionMasks.swift"), "native foreground selection missing")

require('case adjust = "RAW"' in text("StudioInspectorMode.swift"), "RAW workflow tab renamed")
require('case film = "FILM"' in text("StudioInspectorMode.swift"), "FILM workflow tab renamed")
require('case masks = "MASK"' in text("StudioInspectorMode.swift"), "MASK workflow tab renamed")
require('SAMSegmenter(manifest:' in text("RedlampMaskService.swift"), "Redlamp SAM prompt provider missing")
require('mask_fused' in text("MaskMetalEngine.swift"), "fused mask evaluator missing")
require('previewObjectMask(at:' in text("MaskPanelView.swift"), "object hover preview missing")
require('Refine Edges' in text("MaskPanelView.swift"), "edge refinement control missing")
print("REDLAMP WORKFLOW AND MASK SOURCE GATES PASS")

# Edit should have a single global toolbar, not an extra 37pt filename/overflow row.
_app_shell = text("ContentView.swift")
_app_commands = text("SpektraFilmFastApp.swift")
require("editorToolbar" not in edit_view and "StudioFloatingScopes(model: model" in edit_view,
        "Edit reintroduced the redundant filename/ellipsis toolbar")
require(".padding(.top, 45)" not in edit_view and
        ".padding(.top, 45 + StudioLayout.paneInset)" not in edit_view,
        "Edit still reserves height for the deleted toolbar")
require("CommandMenu(\"Workspace\")" in _app_commands and
        "Copy / Paste Categories" in _app_commands and
        "StudioEditEvents.exportCurrentPhoto" in _app_shell and
        "QuickExportSheet(model: model, imageID: request.id)" in _app_shell,
        "secondary Edit actions were removed without accessible native menu replacements")

# October 10 GPU preview/source-bridge integration gate.
_preview = text("PreviewView.swift")
_native = text("NativeRenderer.swift")
_metal_canvas = text("MetalPreviewCanvas.swift")
require("MetalPreviewCanvas(image:" in _preview and "MTKView" in _metal_canvas and "inFlight >= 2" in _metal_canvas,
        "GPU-backed frame presentation and bounded latest-frame scheduling missing")
require("enqueueMetalFilm" in _native and "SpektraRendererRenderMetalBuffers" in _native,
        "Metal-only native engine bridge not accessible from Swift")
# Persistently cached spectral LUTs: never bake inline during slider drag.
_spectral = text("StudioSpectralLUT.swift")
require('case "33": return 33' in _spectral and 'case "65": return 65' in _spectral
        and "default: return nil" in _spectral and "sampleTetra" in _spectral,
        "spectral LUT sampler and explicit resolution gate missing")
require("prewarmLUT" in text("GPULiveFramePipeline.swift") and
        "encodeIfEligible" in text("GPULiveFramePipeline.swift") and
        "if !usedSpectralLUT" in text("GPULiveFramePipeline.swift"),
        "LUT must be warmed outside interactive rendering and use native Metal on miss")
require("SpectralLUTs-v2" in _spectral and "payloadSHA256" in _spectral and
        "Data(contentsOf:" in _spectral and "Data(bytes: staging.contents()" in _spectral,
        "versioned persistent GPU LUT cache missing")
require("colorLUTBlockingReason" in _native and "film grain" in _native,
        "LUT must explain when spatial simulation prevents sampling")
require("Cached film LUT 33³" in settings and "Native spectral (exact)" in settings,
        "persistent LUT settings and original renderer option missing")
require("prepareSelectedFilmLUT()" in settings and "lutIsPreparing" in settings and
        "Cannot bake this look" in text("AppModel.swift") and "lutBlockReason" in text("GPULiveFramePipeline.swift"),
        "Prepare button must call an immediate action and explain actual native eligibility")
require("StudioFloatingScopes(model: model" in edit_view and
        "floatingScopesHeight" in text("StudioFloatingScopes.swift"),
        "contextual scope overlay not connected to Edit canvas")

# Latest Redlamp slider geometry + local Edit photo filtering regression.
require("let thumbX = thumbRadius + usableWidth * fraction" in _ui and
        ".offset(x: thumbX - thumbRadius)" in _ui and
        "let usable = max(1, usableWidth)" in _ui,
        "Redlamp slider fill/center/drag geometry diverged")
require("private var filteredEditPhotos" in edit_view and
        "Photos filter options" in edit_view and
        "ForEach(filteredEditPhotos)" in edit_view,
        "Edit Photos tab filter options are missing")
require("orderedIDs: filteredEditPhotos.map" in edit_view and
        "orderedIDs: [UUID]? = nil" in text("LibraryCullSupport.swift"),
        "Shift selection includes filtered-out photos")

# 2026-10-10 Redlamp source-linked layout audit gates.
_cull = text("CullView.swift")
_library = text("LibraryView.swift")
_settings = text("SettingsView.swift")
_scopes = text("StudioFloatingScopes.swift")
require("private var cullSidebar" in _cull and "ScrollView(.vertical)" in _cull and
        "filmstripHeight" not in _cull and ".popover(isPresented: $showFilters" in _cull,
        "Cull regained its full-width filter ribbon or bottom filmstrip")
require('Label("NAVIGATOR"' in _library and '.listStyle(.sidebar)' in _library and
        'Section("Library")' in _library and 'Section("Folders")' in _library,
        "Redlamp sidebar/navigator Library layout missing")
require(".studioOmniPane()" in _settings and 'Text("Settings")' in _settings and
        'Tab("Models"' in _settings,
        "Settings lost Omni-style contextual glass or working Models tab")
require(".studioOmniPane()" in _scopes and "DragGesture" in _scopes and
        "floatingScopesHeight" in _scopes and "model.setEditorScopeMode" in _scopes and
        'Image(systemName: "xmark")' in _scopes,
        "scopes must remain draggable/resizable/selectable/closable contextual glass")
require('.aspectRatio(CGFloat(image.width) / CGFloat(max(1, image.height)), contentMode: .fit)' in text("EditorScopePanelView.swift"),
        "scope plots were stretched instead of aspect-fitted")
require("StudioExportSectionLayout(" in export_view and 'exportActions' in export_view,
        "modular export controls detached from the original export workflow")
print("2026-10-10 REDLAMP UI REGRESSION GATES PASS")
