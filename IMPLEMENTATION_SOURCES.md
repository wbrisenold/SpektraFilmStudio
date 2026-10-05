# Implementation sources — v0.5.2 Studio Workflow

SpektraFilmFast is an original Swift/AppKit host around the pinned Spektrafilm native renderer. The projects below were used as concrete references for behavior, math, interaction patterns, or factual preset data. Attribution is intentionally explicit. Where licenses differ, SpektraFilmFast reimplements behavior/math in Swift rather than silently dropping upstream source files into the project; factual numeric preset dimensions are identified as data references.

## Spektrafilm renderer

- Repository: https://github.com/chaert-s/spektrafilm-ofx
- Pinned native commit: `8f6651858f439a99b7202b4b8dea59e344dadf5d`
- Use: film / print / scan / grain / halation / diffusion / color-management renderer and the native app bridge.
- Funding link discovered: none in the repository at audit time.

The renderer pin is part of the parity contract. Do not unpin without performance, visual-parity, and release validation.

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
