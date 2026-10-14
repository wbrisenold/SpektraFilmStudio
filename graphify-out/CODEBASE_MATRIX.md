# SpektraFilmStudio Codebase Matrix

> Machine-readable map of the Swift/SwiftUI project for agent navigation.
> Last regenerated: 2026-10-13

## Project Layout

```
Sources/SpektraFilmFast/
├── SpektraFilmFastApp.swift            # @main App, WindowGroup, persistence bootstrap
├── AppModel.swift                      # ObservableObject state, undo/redo, all setters
├── ProjectModels.swift                 # All model structs/enums (RenderLook, PipeSettings, Tone, Geometry, etc.)
├── ControlsView.swift                  # Settings panel UI (RAW / Tone / Geometry / Lens / Color / Pipe tabs)
├── CullView.swift                      # Cull recommendations UI + GPU Filters inspector
├── CullEngine.swift                    # Cull score computation
├── CullPanel.swift                     # Cull panel view
├── NativeRenderer.swift                # Metal-backed render loop, texture mgmt
├── GPULiveFramePipeline.swift          # Live preview GPU pipeline (denoise + lens + tone + bilateral)
├── GPUPipelineRenderer.swift           # Render pipeline wrapper
├── ImageDecoder.swift                  # Image I/O (JPEG/PNG/RAW)
├── ProductionSelfTest.swift            # Startup self-test probe
├── FacetCompositionAnalysis.swift      # Composition analysis (portrait/landscape/etc.)
├── WorkflowDefaults.swift              # Default pipe/tone/geometry presets
└── ToneMapping/                        # Swift + Metal tone engines
    ├── SigmoidToneModule.swift         # Sigmoid tone (Swift + .metal kernel)
    ├── FilmicRGBModule.swift           # Filmic RGB tone (Swift + .metal kernel)
    ├── AgXToneModule.swift             # AgX tone (Swift + .metal kernel)
    ├── SkiaToneModules.swift           # Skia-based tone fallback
    ├── SigmoidKernels.metal
    ├── FilmicRGBKernels.metal
    └── AgXKernels.metal
```

## File → Role / Key Exports Table

| File | Role | Key types / exports | Consumed by |
|-
| `ProjectModels.swift` | Single source of truth for all data models | `RenderLook`, `PipeSettings`, `PipeStage`, `NLMeansPipeParams`, `BilateralPipeParams`, `LensPipeParams`, `SigmoidPipeParams`, `AgXPipeParams`, `FilmicRGBPipeParams`, `ToneSettings`, `ColorDensitySettings`, `GeometrySettings`, `LensEffectsSettings`, `RawSettings`, `LookSettings`, `Project`, `ImageRecord`, enums: `RawWhiteBalanceMode`, `RawDenoiseMode`, `ScopeMode`, `CullRecommendation`, `GeometryAutoMode`, `CropOverlayGuide` | Every other file |
| `AppModel.swift` | ObservableObject; undo/redo, all mutation setters, derived state | `AppModel` (class ObservableObject), `setToneContrast(_:)`, `setToneMidtoneShift(_:)`, `setToneHighlight rolloff(_:)`, `setToneShadow rolloff(_:)`, `setColorDensity(_:_:)`, `resetColorDensity()`, `setGeometrySettings(_:)`, `resetGeometry()`, `setLensEffectsSettings(_:)`, `resetLens()`, `mutateTone`, `mutateGeometry`, `mutateLens`, `mutateColorDensity`, `mutateRawDevelop`, `setPipeStage(_:)`, `setPipeToneEngine(_:)`, `resetPipe()`, `setPipeParam(_:_:)` | `ControlsView`, `CullView`, `NativeRenderer`, `GPULiveFramePipeline` |
| `ControlsView.swift` | Settings panel UI; tabbed sections for each pipeline domain | `ControlsView` (struct View), `pipeSection`, `pipeStageHelp`, `PipeToggleRow`, `PipeParamSliders`, `SettableKey`, `ControlSection`, extension `String.uppercasedFirstLetter()`, `PipeStage.displayName`, `ToneEngineSelection.displayName` | Hosted in `SpektraFilmFastApp` |
| `CullView.swift` | Cull recommendations + GPU Filters inspector UI | `CullView` (struct View), GPU filter inspector that reads/writes `RenderLook.pipe` stages | Hosted in `SpektraFilmFastApp` |
| `CullEngine.swift` | Computes cull recommendation from image metadata + look | `CullEngine` (struct), score functions | `CullPanel`, `AppModel` (via cull logic) |
| `CullPanel.swift` | Cull panel presentation | `CullPanel` (struct View) | Hosted in `SpektraFilmFastApp` |
| `NativeRenderer.swift` | Metal device/queue, texture lifecycle, render loop, main display | `NativeRenderer` (class), command buffer orchestration, swapchain-like ping-pong | `SpektraFilmFastApp`, `GPULiveFramePipeline` |
| `GPULiveFramePipeline.swift` | Live-preview GPU chain: NLMeans → Bilateral → Lens → Tone (sigmoid/agx/filmicRGB) | `GPULiveFramePipeline` (actor), `render()`, per-stage encode calls into `NLMeansDenoiseModule` / `BilateralBlurModule` / `LensCorrectionModule` + tone modules. **Pipe stages operate on textures**: buffer→texture before pipe, texture→buffer after. All temp textures retained via command buffer. Uses `renderBuffer`/`renderKeepAlive` (renamed from `result`/`keepAlive`). | `NativeRenderer`, `AppModel` (read pipe state) |
| `GPUPipelineRenderer.swift` | Render pipeline wrapper (Metal pipeline states) | `GPUPipelineRenderer` (class) | `NativeRenderer` |
| `ImageDecoder.swift` | Loads JPEG/PNG/RAW into Metal textures | `ImageDecoder` (struct), `load(_:)` | `AppModel` (import), `NativeRenderer` |
| `SpektraFilmFastApp.swift` | @main entry; WindowGroup; state persistence; self-test on launch | `SpektraFilmFastApp` (struct App), `ContentView` | Everything (root) |
| `ProductionSelfTest.swift` | Probes Metal.device, tone modules, pipe modules at startup | `ProductionSelfTest` (struct), `run()` | `SpektraFilmFastApp` (on launch) |
| `WorkflowDefaults.swift` | Default presets for pipe/tone/geometry/lens/color | Default `PipeSettings`, default `ToneSettings`, etc. | `AppModel`, `ControlsView` |
| `FacetCompositionAnalysis.swift` | Composition classification | `FacetCompositionAnalysis` (struct) | `CullEngine` |
| `ToneMapping/SigmoidToneModule.swift` | Sigmoid tone engine (Swift + Metal kernel) | `SigmoidToneModule` (class), `Params`, `encode(...)` | `GPULiveFramePipeline`, `NativeRenderer` |
| `ToneMapping/FilmicRGBModule.swift` | Filmic RGB tone engine | `FilmicRGBModule` (class), `Params` (with `simd_float3x3` colorMatrix), `encode(...)` | `GPULiveFramePipeline`, `NativeRenderer` |
| `ToneMapping/AgXToneModule.swift` | AgX tone engine | `AgXToneModule` (class), `Params` (gamutCompression, etc.), `encode(...)` | `GPULiveFramePipeline`, `NativeRenderer` |
| `ToneMapping/SkiaToneModules.swift` | Skia-based tone fallback | Skia tone wrapper | `NativeRenderer` (fallback path) |
| `ToneMapping/*.metal` | Metal shader source for each tone engine | Kernel functions: `spektra_sigmoid_*`, `spektra_filmicrgb_*`, `spektra_agx_*` | Compiled into respective tone module classes |
| `ImageProcessing/ImageProcessingModules.swift` | GPU image-processing module classes (port from Lightamer) | `NLMeansDenoiseModule`, `BilateralBlurModule`, `LensCorrectionModule`, `CropModule`, `FlipModule`, `SharpenModule`, `LiquifyModule`(stub), `RetouchModule`(stub), shared uniform structs `BilateralDirectUniforms`, `LensUniforms` | `GPULiveFramePipeline`, `NativeRenderer` |

## Data Flow (read-only summary)

1. `AppModel.project` holds `[ImageRecord]`, each with `look: RenderLook`.
2. `RenderLook` carries `pipe: PipeSettings`, `tone: ToneSettings`, `colorDensity: ColorDensitySettings`, `geometry: GeometrySettings`, `lens: LensEffectsSettings`, `raw: RawSettings`.
3. `ControlsView` / `CullView` call `AppModel` setters → mutate `project.images[i].look` → push undo → schedule refinement.
4. `NativeRenderer` runs the display loop; for live preview it delegates to `GPULiveFramePipeline`, which reads current `RenderLook.pipe` + tone engine and encodes the appropriate Metal modules.
5. `GPULiveFramePipeline` encodes: NLMeans (if `pipe.stages[.nlmeans]`) → Bilateral (if `pipe.stages[.bilateral]`) → Lens (if `pipe.stages[.lens]`) → Tone engine (sigmoid/agx/filmicRGB if selected) → output to display texture.
6. Tone modules: Sigmoid / FilmicRGB / AgX are mutually exclusive in the live path; UI enforces one active tone engine at a time.
7. Settled/export path is separate from live preview; pipe stages are opt-in preview only and do not change the settled/export path.

## Rendering Path Key Decision Points

| Gate | What it controls | Where |
|-
| `pipe.stages[X]` bools | Whether a given pipe stage runs in live preview | `GPULiveFramePipeline.run()` |
| `pipe.toneEngine` | Which tone engine (sigmoid/agx/filmicRGB/none) is applied live | `GPULiveFramePipeline.run()` |
| `raw.denoiseMode` | Forces exact renderer for RAW develop path when ≠ .off | `GPULiveFramePipeline` / settle path |
| One tone engine active | UI enforces mutual exclusion in `ControlsView.pipeParamSliders` | `ControlsView` |

## AppModel Setter Catalog (mutation API)

| Setter | Mutates | Notes |
|-
| `setToneContrast(_:)` | `look.tone.contrast` | Undo + scheduleIdleRefinement(changedParameter: "toneContrast") |
| `setToneMidtoneShift(_:)` | `look.tone.midpointShift` | |
| `setToneHighlightRolloff(_:)` | `look.tone.highlightRolloff` | |
| `setToneShadowRolloff(_:)` | `look.tone.shadowRolloff` | |
| `setColorDensity(_:_:)` | `look.colorDensity.compensation` / `.halfLift` | Two-float variant |
| `resetColorDensity()` | `look.colorDensity = ColorDensitySettings()` | |
| `setGeometrySettings(_:)` | `look.geometry` (full struct) | Resume render after mutation |
| `resetGeometry()` | `look.geometry = GeometrySettings()` | |
| `setLensEffectsSettings(_:)` | `look.lens` (full struct) | |
| `setPipeStage(_:_:)` | `look.pipe.stages[X]` bool | New — added for pipe UI |
| `setPipeParam(_:_:)` | `look.pipe.nlmeans/bilateral/lens/sigmoid/agx/filmicRGB` param field | New — generic Float setter via switch |
| `setPipeBoolParam(_:_:)` | `look.pipe` bool param field (e.g., agx.enableLook, agx.gamutCompression) | New — Bool variant |
| `resetPipe()` | `look.pipe = PipeSettings()` | New — resets all pipe stages + params |
| `setPipeToneEngine(_:)` | `look.pipe.toneEngine` | New — sets active tone engine |
| `mutateTone` / `mutateGeometry` / `mutateLens` / `mutateColorDensity` / `mutateRawDevelop` | In-place mutation via closure | Used by interactive sliders with debounce |

## ControlsView Sections (UI tabs)

| Section var | Domain | Controls |
|-
| `rawSection` | RAW develop | White balance, exposure, RAW denoise mode |
| `toneSection` | Film/tone | Tone engine segmented control + per-engine sliders (contrast/midtones/highlights/shadows) |
| `geometrySection` | Geometry | Crop, rotation, aspect, auto-mode |
| `lensSection` | Lens | Distortion, TCA, vignette sliders |
| `colorDensitySection` | Color density | Compensation + half-lift sliders |
| `pipeSection` | GPU filter pipeline (NEW) | Stage enable/disable toggles (NLMeans/Bilateral/Lens/Tone), tone engine picker, per-stage param sliders via `PipeParamSliders` |
| `pipeStageHelp` | GPU filter pipeline help text | Stage descriptions |

## Pipe Stages & Their Param Structs

| Stage | Param struct | Fields |
|-
| `.nlmeans` | `NLMeansPipeParams` | `radius: Float`, `strength: Float`, `luma: Float`, `chroma: Float` |
| `.bilateral` | `BilateralPipeParams` | `radius: Float`, `redSigma: Float`, `greenSigma: Float`, `blueSigma: Float` |
| `.lens` | `LensPipeParams` | `distortionK1..K4`, `tcaRed`, `tcaBlue`, `vignetteK1..K4` |
| `.sigmoid` | `SigmoidPipeParams` | sigmoid-specific tone params |
| `.agx` | `AgXPipeParams` | `enableLook: Bool`, `gamutCompression: Bool`, plus float params |
| `.filmicRGB` | `FilmicRGBPipeParams` | `colorMatrix: simd_float3x3?` (non-Codable/non-Hashable), plus float params |
| `.mosaic` | `RawMosaicPipeParams` | F32 mosaic params |

## Known Build Issues (as of last build attempt)

| File | Issue | Status |
|-
| `GPULiveFramePipeline.swift` | **FIXED**: `.encode(input: nil, output: nil)` → real textures via `gpu.makeOutputTexture()` + `gpu.encodeBufferToTexture()`/`encodeTextureToBuffer()`. All pipe stages run on textures with proper buffer↔texture conversion. Temp textures retained via command buffer. | Fixed (2026-10-13) |
| `ToneMapping/FilmicRGBModule.swift` | `simd_float3x3` does not conform to `Codable`/`Hashable`; was in `Params` struct | Fixed (removed Codable/Hashable from Params; kept Sendable) |
| `ControlsView.swift` | `PipeToggleRow.body` and `PipeParamSliders.body` type-check timeout — fixed by flattening body. `String.uppercasedFirstLetter()` extension moved to top of file (was on `PipeStage`/`ToneEngineSelection`). `PipeStage.displayName`/`ToneEngineSelection.displayName` helpers added. | Fixed (2026-10-13) |
| `AppModel.swift` | Missing `setPipeStage`, `setPipeParam`, `setPipeBoolParam`, `setPipeToneEngine`, `resetPipe` | Fixed (added) |
| Build | `swift build` succeeds with **zero errors and zero warnings** after all fixes (2026-10-13) | Passes (clean) |

## Build & Run Commands

```bash
# Build (warnings OK, zero errors target)
swift build

# Run the app (macOS)
swift build && .build/debug/SpektraFilmFast

# Or launch the built product directly
open dist/SpektraFilmStudio.app
```

## Where to Edit for Common Tasks

| Task | Files to touch |
|-
| Add a new pipe stage | `ProjectModels.swift` (add stage to `PipeStage` enum + param struct + add to `PipeSettings`), `ControlsView.swift` (add toggle in `pipeSection` + param sliders in `PipeParamSliders`), `GPULiveFramePipeline.swift` (add encode block in `run()`), `AppModel.swift` (add param setter case if new params), `ImageProcessing/ImageProcessingModules.swift` (add module class if new GPU kernel) |
| Add a new tone engine | `ProjectModels.swift` (add to tone engine enum), `ToneMapping/` (new module class + .metal), `GPULiveFramePipeline.swift` (encode path), `ControlsView.swift` (segmented control + sliders), `AppModel.swift` (setter if needed) |
| Change live preview order | `GPULiveFramePipeline.swift` `run()` method |
| Change undo/redo behavior | `AppModel.swift` (undoStack/redoStack + mutate* helpers) |
| Add a new settings tab | `ControlsView.swift` (add section var + case in switch) |
| Change defaults | `WorkflowDefaults.swift` |

## Cross-Reference: Tone Engine ↔ Module Class ↔ Metal Kernel

| Engine | Swift class | Metal kernel file | GPULiveFramePipeline path |
|-
| Sigmoid | `SigmoidToneModule` (ToneMapping/SigmoidToneModule.swift) | ToneMapping/SigmoidKernels.metal | encoded when `pipe.toneEngine == .sigmoid` |
| Filmic RGB | `FilmicRGBModule` (ToneMapping/FilmicRGBModule.swift) | ToneMapping/FilmicRGBKernels.metal | encoded when `pipe.toneEngine == .filmicRGB` |
| AgX | `AgXToneModule` (ToneMapping/AgXToneModule.swift) | ToneMapping/AgXKernels.metal | encoded when `pipe.toneEngine == .agx` |
