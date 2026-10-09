# Implementation sources — v0.5.2 Studio Workflow

SpektraFilmFast is an original Swift/AppKit host around the pinned Spektrafilm native renderer. The projects below were used as concrete references for behavior, math, interaction patterns, or factual preset data. Attribution is intentionally explicit. Where licenses differ, SpektraFilmFast reimplements behavior/math in Swift rather than silently dropping upstream source files into the project; factual numeric preset dimensions are identified as data references.

## Spektrafilm renderer

- Repository: https://github.com/chaert-s/spektrafilm-ofx
- Pinned native commit: `8f6651858f439a99b7202b4b8dea59e344dadf5d`
- Use: film / print / scan / grain / halation / diffusion / color-management renderer and the native app bridge.
- Vendored: yes, under `Native/` (source + generated curves). GPLv3 into a GPLv3 project; see `Native/NOTICE.md`.
- Funding link discovered: none in the repository at audit time.

The renderer pin is part of the parity contract. Do not unpin without performance, visual-parity, and release validation. Because the sources are vendored at that commit, the pin is enforced by the source gate rather than by a network fetch: the build cannot silently move to a newer upstream revision.

## RapidRAW

- Repository: https://github.com/CyberTimon/RapidRAW
- Reference revision used for current architecture/math study: `ad80dd6cd6fe7d40ea3101fabfa72d4251f06899`
- Upstream funding: https://ko-fi.com/cybertimon
- Upstream license at audit time: AGPL-3.0.

Concrete references studied:

- preview worker that drains queued jobs to the newest request (latest-request-wins/backpressure);
- cached transformed preview + smaller interactive render strategy;
- dynamic editor preview sizing and high-resolution zoom refinement;
- export defaults in `src-tauri/src/app_settings.rs`:
  - High Quality: JPEG 95, no resize, metadata kept;
  - Fast (Web): JPEG 80, width 2048, don't enlarge, metadata removed/GPS-safe delivery;
- current WGSL tone behavior as a reference for independently implemented Swift controls:
  - filmic Brightness luma shaping;
  - middle-tone crossover/masking concepts;
  - bright-end recovery/compression behavior;
  - perceptual shadow lift/recovery behavior.

No RapidRAW Rust/WGSL source file is bundled in this repository. Keep this provenance note if the Swift math is changed.

## Alcedo Studio

- Repository: https://github.com/zidage/AlcedoStudio
- Observed revision: `a5ca4c36e47b9df951d71726bf157355e5148125`
- Upstream funding/support link: https://github.com/zidage/AlcedoStudio/discussions/44

References studied:

- professional Tone panel ordering;
- normalized point-curve interaction and monotone Hermite behavior;
- ACEScc encode/decode and Exposure-as-EV-offset semantics;
- always-available compact scope presentation.

The Swift UI/math is implemented locally rather than bundling Alcedo source files.

## darktable

- Repository: https://github.com/darktable-org/darktable
- Observed revision: `d53157453ef713133b8edc564ec6870ce31ba806`
- Repository funding URL discovered: none at audit time.

References studied:

- `rgbcurve.c` published built-in node data for technical point-curve presets;
- non-destructive normalized crop/aspect behavior;
- perspective/keystone workflow and automatic black-edge handling concepts;
- `src/iop/levels.c` automatic/manual Levels behavior: 16,384-bin histogram analysis,
  black/white boundary discovery, and chroma-preserving luminance scaling. SpektraFilmFast's
  Auto Contrast is an independent Swift adaptation for its linear RGB buffer;
- `src/iop/overexposed.c` and darktable's clipping-warning UI: Full Gamut / Any RGB /
  Luminance / Saturation modes, red-over / blue-under display language, upper/lower
  threshold semantics, and the -12.69 EV 8-bit sRGB black reference. SpektraFilmFast
  independently implements the behavior against its own final post-film/post-geometry
  render buffer; no darktable source file is bundled.

## RawTherapee

- Repository: https://github.com/Beep6581/RawTherapee
- Repository funding URL discovered: none at audit time.

Used as a cross-check for mature RAW-editor interaction/clipping conventions and non-destructive workflow behavior.

## Primera Suite

- Repository: https://github.com/geoffsmithBK/primera-suite
- Repository funding URL discovered: none at audit time.
- Upstream license at audit time: MIT.

References studied:

- `PrimeraHue.dctl` density behavior: subjective color density, complementary RGB/CMY controls, optional luminance preservation;
- `src/frag/skintone.dctlf`, `src/PrimeraSkin/body.dctlc`, and project documentation: rg-chromaticity skin qualification, spatial mask pooling / soft-union to fill noisy qualification holes, and the three-zone Show Mask convention in which green/cyan-side, on-skin gold, and magenta-side deviations are visibly distinct.

SpektraFilmFast combines these color ideas with final-render subject isolation; it does not bundle the DCTL files.

## Vectorscope Skin Tone Analyzer

- Repository: https://github.com/DeoTime/vectorscope
- Observed main revision: `123dfc96d3f5af1426cd7a2f5c185d2c4f386c49`
- Repository funding URL discovered: none at audit time.

Published BT.601 YCbCr and broad HSV skin ranges, vectorscope polar/deviation concepts, and skin-line analysis were used as references. SpektraFilmFast adds Apple Vision subject isolation and a confidence-weighted final-render skin centroid.

## filmr

- Repository: https://github.com/W-Mai/filmr
- Observed revision: `fee388e213dd77bfe6977b63071b1c136213373a`
- Repository funding URL discovered: none at audit time.

Its open implementation/documentation of photographic H-D response using toe/straight-line/shoulder/logistic concepts informed the **Film Response** master-curve recipes. These presets are intentionally described as response shapes, not exact named film-stock color emulations. Spektrafilm remains responsible for actual stock simulation.

## OpenPost social output dimensions

- Repository: https://github.com/getopenpost/openpost
- File referenced: `apps/server/internal/api/handlers/image_editor.go`
- Upstream license at audit time: AGPL-3.0.
- Repository funding URL discovered: none at audit time.

Only published numeric canvas dimensions are referenced:

- Instagram Square: 1080 × 1080
- Instagram Portrait: 1080 × 1350
- Story / Reel / TikTok: 1080 × 1920
- LinkedIn Square: 1200 × 1200
- LinkedIn Landscape: 1200 × 627
- X Landscape: 1600 × 900
- YouTube Thumbnail: 1280 × 720

No OpenPost implementation code is bundled.

## ProofDock

ProofDock v0.1.6 is the user's existing proofing project/workflow and is integrated as the Proofs subsystem. It supplies the intended short-link/client-selection behavior, including `/g/<code>` URLs, no-login client selection, cover/Open Graph preview, heart/fullscreen interactions, Finish Selection, link regeneration, and selection round-trip.

## Apple platform technologies

Not open-source references, but important runtime/platform dependencies:

- Apple Vision — person segmentation, face rectangles, and local image feature prints used for People / Face Groups;
- Core Image / CIRAWFilter — RAW development and camera-neutral WB operations;
- Accelerate/vImage — high-quality scaling and interactive image math;
- Metal — native renderer execution;
- SwiftUI / AppKit — application UI;
- ImageIO — thumbnail/metadata/export encoding and validation.

## Original SpektraFilmFast recipes/behavior

The following are intentionally original product recipes/implementations rather than falsely attributed upstream presets:

- Creative WB recipes (Golden Hour, Sunset, Sunrise, Blue Hour, Candlelight, etc.); they run as relative per-image offsets on As Shot or Auto.
- Creative and Film Response master-curve recipes beyond explicitly published darktable technical node sets.
- Black Point / White Point host control mapping.
- Combined final-render skin confidence model and professional overlay presentation.
- Native Swift Proofs administration UI around the ProofDock workflow.

If future work copies source rather than studying/reimplementing behavior, update `NOTICE.md`, this document, and the project license obligations before redistribution.
## 2026 workflow / performance audit

See `docs/DEVELOPMENT_HISTORY.md`.

Additional implementation references used by this revision:

- darktable lighttable / culling / export — selection-aware culling modes,
  collection decisions, output dimensions/profile/metadata separation;
- RapidRAW export UI — modern delivery and export-set presentation;
- current `andreavolpato/spektrafilm` runtime and LUT creator — named
  film/print taps, multi-LUT topology and documented spatial insertion points;
- Apple Accelerate/vDSP — vectorized float-to-integer export conversion;
- Apple `os_proc_available_memory()` — advisory byte-budgeted decode-ahead.

The shipping build remains Intel x86_64 only.


## Alcedo Studio UI reference (2026-10)

The Presets and Export workspace redesign uses interaction/layout ideas from
Alcedo Studio's GPL-3.0 open-source UI, especially its inspector-driven export
panel, persistent export progress area, compact grouped controls, filename
pattern editor, and queue presentation.

Source: https://github.com/zidage/AlcedoStudio
Relevant upstream files:
- `alcedo_studio/src/ui/alcedo_main/qml/ExportInspectorPanel.qml`
- `alcedo_studio/src/ui/alcedo_main/qml/ExportNamingEditor.qml`

SpektraFilmFast keeps its own SwiftUI implementation, export engine, file
formats, metadata behavior, queue recovery, timing/ETA data, and no-LUT exact
render pipeline. The visual-preset grid, exact rendered preset thumbnails,
favorites, recents, and hover preview are SpektraFilmFast additions.


## Alcedo Studio export execution architecture (Stage 1)

Reference:
- https://github.com/zidage/AlcedoStudio
- audited revision: f1fae5dc548931f2f94028cf033fe6d693bdffd7

Files/areas studied:
- `alcedo_studio/src/app/export_service.cpp`
- `alcedo_studio/src/io/image/image_writer.cpp`
- export executor-pool / renderer scheduling code

Architecture carried over:
- full-resolution render remains full-resolution;
- resize happens after render;
- accelerator render does not wait for the previous file encode;
- post-render CPU work is concurrent and bounded;
- file encoding is not serialized through one actor;
- memory admission controls full-resolution frames retained in flight.

SpektraFilmFast keeps its own Swift/Metal exact renderer, ImageIO writer,
recovery journal, timing log, color pipeline, and Intel-only build.


## Alcedo Studio mask / local-grade architecture (Stage 2)

Reference repository: https://github.com/zidage/AlcedoStudio
Audited revision: f1fae5dc548931f2f94028cf033fe6d693bdffd7

Architecture carried over:
- each local/color grade owns its mask stack;
- mask sources are ordered;
- source controls include enabled, invert, feather and opacity;
- stack combination supports add, subtract and intersect;
- mask coverage is separate from the grade result;
- the final operation composites a separately rendered grade through coverage.

Alcedo files/areas used as architecture references include:
- `alcedo_studio/src/include/edit/runtime/compiled_mask_stack.hpp`
- `alcedo_studio/src/include/edit/runtime/compiled_grade_mask.hpp`
- `alcedo_studio/src/edit/runtime/graph_compiler.cpp`
- node/mask editor roadmap and mask-group UI

SpektraFilmFast keeps its own exact film renderer. Stage 2 adds a generic Metal
coverage/compositor beside it rather than rewriting the film math.


## Current AI masks: Redlamp port

Redlamp source revision `0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd`, https://github.com/pdcgomes/redlamp, MPL-2.0. Selected masking, matting, model inference and supporting math files are adapted as `Redlamp*.swift`; upstream headers remain, and `Resources/Redlamp-MPL-2.0.txt` contains the license. Adaptations include Spektra's persisted grade API, Intel binary16 handling and Core ML execution, model storage, and full-resolution bitmap integration. UI and fused coverage integration are local Swift/Metal implementations.

Exact upstream model catalogs are in `Resources/MaskModels`: SAM 2.1 Tiny, SAM 3, Depth Anything 3 Mono Large, Depth Anything V2 Small and ViTMatte Base. Preserve their per-model licenses and notices. SAM 3 snow prompts and Meta license are in `Resources/SAM3`. Apple Vision and embedded iPhone mattes need no downloaded weights. Legacy MODNet, SCHP and BiSeNet parsers are no longer used or packaged by the current masking flow; existing local model files are retained.

## Stage 4 RAW quality / monitoring
- RawForge 0.2.4: https://github.com/rymuelle/RawForge and https://pypi.org/project/rawforge/0.2.4/ (MIT).
- False-color monitor design references OBS Color Monitor false-color documentation: https://github.com/norihiro/obs-color-monitor and photographic-dctls exposure/false-color work: https://github.com/mikaelsundell/photographic-dctls .
- Lens parameter/preset research references open lens/post-FX implementations including https://github.com/artzox/Film-Standalone and measured-lens project https://github.com/Dylanyz/DynamicLens . SpektraFilmFast implementation is original Swift math, not copied shader code.


## Stage 5 production hardening
- Uses Apple's public Metal compute APIs already linked by SpektraFilmFast; the Stage 5 lens kernel is an original port of the Stage 4 reference math.
- RawForge remains the Stage 4 pinned MIT dependency; Stage 5 adds orchestration, prewarming, timing and cache accounting without changing the RawForge model.

## ME deSatch color-density behavior
- ME_Desatch.dctl from Moaz Elgabry's DCTLs repository, pinned reference revision `5e57387d486e82e416cf25bc8a95aad5e7f33c7a` (GPL-3.0).
- SpektraFilm Studio adapts its cone-coordinate radius/hue/polar behavior into Swift for Color Density; the implementation is modified for the host-grade pipeline and project model.
- Upstream credits and provenance are preserved in `THIRD_PARTY/ME_Desatch/NOTICE`.


### SAM 2.1 Tiny object selection
Apple conversion: https://huggingface.co/apple/coreml-sam2.1-tiny at revision `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306`. Meta SAM 2.1 Hiera Tiny, Apache-2.0; license bundled at Resources/SAM2-LICENSE.txt. The editor uses the adapted Redlamp tensor contract and provider. An independent adapter remains for compatibility tests. All files are byte-count and SHA-256 pinned.

### Redlamp film finish

Light leaks, dust, scratches, hash/noise helpers and four frame styles are directly ported from `packages/RedlampKernels/Sources/Shaders/Develop.metal` at Redlamp commit `0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd`, under MPL-2.0. `RedlampFilmEffectsEngine.swift` retains those shader functions; the local adapter adds GPU dispatch, native-output transfer handling, saved settings and a Film Finish panel. These effects do not replace the spectral film renderer. Source: https://github.com/pdcgomes/redlamp/blob/0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd/packages/RedlampKernels/Sources/Shaders/Develop.metal

### Experimental spectral LUT path (2026-10-08)

An opt-in native test path bakes one 129³ FLOAT32 film-density → linear-output RGB
texture using the original pinned OFX equations. GPU cubic B-spline interpolation
uses eight filtered samples; near-zero channels and out-of-domain densities use
original GPU equations. Spatial/stochastic stages remain separate. Embedded MSL
is adapted GPLv3 source from OFX revision 8f6651858f439a99b7202b4b8dea59e344dadf5d.
The Python LUT creator informed the boundary, but is not a bundled dependency.
Automatic LUT export is disabled: the Radeon benchmark was slower than native.

Fast DIR color is a saved host setting that zeros only DIR diffusion radii,
retaining inhibition/channel chemistry. It applies to preview and export.
Existing projects retain their original diffusion until enabled. Interactive
previews now retain chemistry while bypassing diffusion rather than disabling DIR.

### Exact GPU stage reuse and fast halation (2026-10-08)

Local host code in SpektraMetalRenderer.mm caches developed film density and,
for smaller preview frames, the linear RGB before scanner processing. Complete
source bytes and conservative upstream keys (including the DIR matrix) establish
identity; downstream printing/scanner settings are excluded only at their correct
boundary. Cache publication follows successful GPU completion. It is bounded,
released under memory pressure and disabled for exports/external asynchronous buffers.

SpektraSpatialShader.h contains local GPU box reduction, bilinear reconstruction
and bit-preserving stage-copy kernels. Broad halation uses the original pinned
physics kernels at half size with physical pixel size adjusted accordingly; its
fine scatter core stays full size. Grain preview policy changes only a transient
look, preserving the selected saved/export model. Reduced diffusion and alternate
scanner blur candidates were rejected; their code is not enabled or shipped here.


### Export interface design (2026-10-09)

The native SpektraFilmStudio Export Workspace and Quick Export sheet were redesigned
using the *interaction model* and structured export settings from Redlamp's
MPL-2.0 export implementation as a design reference (no Redlamp Swift source copied).
Reference: https://github.com/pdcgomes/redlamp/tree/d8a892a259ccdaa12f1041ff01f88ce8e7ce68af/packages/RedlampUI/Sources/Export
Unlike Redlamp, this application retains its existing JPEG/HEIC/TIFF output
capabilities, no-overwrite policy, batch queue and Spektrafilm rendering engine.
User-defined export presets are stored in local app preferences.

### Studio-wide UI design reference (2026-10-09)
Redlamp's editing surface, navigation, compact controls and panel geometry are
used as reference; pdcgomes/redlamp at d8a892a259ccdaa12f1041ff01f88ce8e7ce68af,
MPL-2.0: https://github.com/pdcgomes/redlamp .

### Native glass, omnibox and Scene Intelligence (2026-10-09)

UI patterns studied from Redlamp's `EditorSplitViewController.swift`, `ThemeSettings.swift`,
`CommandPaletteView.swift`, `PaletteCatalog.swift` and `SearchMatcher.swift`, reference
`d8a892a259ccdaa12f1041ff01f88ce8e7ce68af` (MPL-2.0):
https://github.com/pdcgomes/redlamp
This implementation is original SwiftUI/AppKit code. No Redlamp source file has been
copied. On macOS 26 it uses Apple's SwiftUI `glassEffect`, with material fallback on
macOS 15. The on-device scene model uses Apple Vision image feature prints and image
classification. Stock/paper choices reference the unchanged, pinned Spektrafilm native
catalog by index and use transparent rules, NOT an upstream film-trained model.
No online AI services or licensing weights are bundled.

### Direct Redlamp source port (MPL-2.0)

The following **real upstream code** was ported from `pdcgomes/redlamp` commit
`d8a892a259ccdaa12f1041ff01f88ce8e7ce68af` under Mozilla Public License 2.0.
Reproduced with namespace/host-integration edits in the listed files:

- `Sources/SpektraFilmFast/RedlampPortedUI.swift`: original `FloatingPane`
  (`packages/RedlampUI/Sources/Editor/EditorView.swift`), `Metrics`
  (`packages/RedlampDesign/Sources/Tokens/Metrics.swift`), `PaletteMetrics`
  (`packages/RedlampUI/Sources/CommandPalette/CommandPaletteView.swift`),
  and `PaletteQueryField`/`PaletteTextField`
  (`packages/RedlampUI/Sources/CommandPalette/PaletteQueryField.swift`).
- `Sources/SpektraFilmFast/RedlampSearchMatcher.swift`: original `SearchMatcher`
  (`packages/RedlampUI/Sources/Model/SearchMatcher.swift`).

Upstream source: https://github.com/pdcgomes/redlamp/tree/d8a892a259ccdaa12f1041ff01f88ce8e7ce68af
License copy: `THIRD_PARTY/Redlamp-Design/LICENSE-MPL-2.0.txt`.

SpektraFilmStudio-specific glue in `StudioUI`, `EditView`, `ControlsView`,
`PresetBrowserView` and `StudioOmniSearch` is a host adaptation. The existing
Spektrafilm renderer, Native/, stock/print index and user project formats are
unchanged. macOS 26 gets Redlamp's ConcentricRectangle Liquid Glass; older
macOS uses a material fallback, with Reduce Transparency taking precedence.
