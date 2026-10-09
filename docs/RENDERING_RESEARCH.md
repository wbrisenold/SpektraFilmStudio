# Rendering research and validation status

The native spectral film equations and generated profile curves remain unchanged. The host now selects the discrete GPU where available. Analytical scene tone, ACEScc curves, color density and film-input shaping have a Metal implementation; the previous implementation is retained for numerical regression checks, not a runtime fallback.

A standalone Radeon test compared 27 tone configurations with and without color density plus film-input shaping. It included negative and above-white values, non-linear curves and automatic contrast. Maximum relative host-grade error was 0.0000036013 (0.00036%). A preliminary 1920×1280 three-run median was 120.20 ms GPU versus 10265.70 ms for the previous CPU host grade. Other compilation/model work was running: these are stage measurements, not an isolated end-to-end benchmark or proof of Lightroom speed.

## Relevant upstream approaches

- [Redlamp](https://github.com/pdcgomes/redlamp): GPU-resident surfaces, cached working images, latest-request rendering and fused adjustments. Apple Silicon performance is not a prediction for an Intel Radeon Mac.
- [Alcedo Studio](https://github.com/zidage/AlcedoStudio): GPU processing, cached affected stages and region-based zoom rendering.
- [SpektraFilm OFX](https://github.com/chaert-s/spektrafilm-ofx): the original physics renderer; spatial-stage caching and resolution management preserve its underlying calculation.
- [vkdt](https://github.com/hanatos/vkdt): a GPU shader graph, including film processing. This supports keeping intermediate images on the GPU rather than replacing physics with LUTs.
- [darktable](https://github.com/darktable-org/darktable): processing-stage caches and GPU execution; its platform/backend behavior should not be copied as a promise of GPU-only operation.
- [RawTherapee](https://github.com/RawTherapee/RawTherapee): vectorized native processing. Broad unsafe floating-point optimizations can alter rendering and require image comparisons.
- [Filmulator](https://github.com/mermerico/filmulator): physics-based film development, useful as an architectural reference rather than a replacement for the current color response.

The next large architectural gain is retaining intermediate Metal buffers/textures through the entire graph. Current adapters still upload and read back arrays between stages. RAW codecs, metadata, bitmap serialization and some existing spatial/analysis operations still use CPU work. The implementation is not yet an entirely GPU-resident renderer.

## AI hardware issue

Exact Redlamp SAM2 weights produce non-finite image embeddings on the Radeon Pro 555X. A diagnostic higher-precision image encoder also failed. Invalid embeddings/masks are rejected rather than committed to an edit. The app does not retry with CPU-only inference. Core ML exposes CPU+GPU scheduling, not an exclusive GPU compute-unit setting; unsupported operators may still be scheduled by the framework on the CPU. The exact same weights passed actual inference on the paired Intel UHD 630 GPU: coverage, background rejection, orientation, repeat/changed prompts and invalid input. SAM2 now selects that GPU specifically on Radeon Pro 555X dual-GPU hardware; photo processing retains the Radeon. First probe took 47.30 seconds including load/first-use work. The optional-model GPU matrix remains pending.

## Direct Redlamp film effects

Light leaks, dust, scratches and frame functions are ported directly from Redlamp Develop.metal at commit 0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd, under MPL-2.0. A standalone Radeon execution test passed all four frames, leak/surface changes, finite output and deterministic repeat rendering. Full application validation is separate.

## 2026-10-08 measured DIR/LUT comparison

Intel x86_64 / Radeon Pro 555X, 3000×2000 landscape fixture, median of three
warm renders per path. Full spatial DIR native: 145.15 ms; full DIR LUT:
275.74 ms. Non-spatial DIR native: 75.70 ms; non-spatial DIR LUT: 156.86 ms.
These separate runs are indicative, not a broad photo-suite guarantee.
The LUT is therefore experimental and disabled in application exports.
Fast DIR color retains the non-spatial chemistry, reducing nine GPU passes
in this example. Spatial edge contrast changes; it is a saved opt-in choice.
The 25-case synthetic LUT matrix passes max relative error 0.00090134 and
RMS 0.00005101. This does not establish perceptual identity for all photographs.

## Exact stage reuse and spatial quality gates

The application now reuses developed film density for downstream print edits,
and caches linear RGB before scanner processing for smaller previews. Source
bytes and conservative upstream uniforms establish identity, including DIR's
matrix. The combined CPU-source/private-GPU cache is bounded to 256 MiB, is
released under memory pressure, and is bypassed for full-resolution exports.
Color-adaptation and asynchronous external-buffer renders bypass this cache.
The 25-case cache matrix is pixel-identical. Explicit invalidation checks cover
source bytes, DIR matrix, exposure, halation, camera diffusion and memory release;
reuse checks cover print exposure, print diffusion, scanner and output/HDR settings.

Warm medians from three paired runs on this Intel/Radeon machine:

| Workload | Original | Updated | Output difference |
| --- | ---: | ---: | --- |
| 6 MP landscape with halation, repeat film-stage reuse | 613.02 ms | 77.21 ms | Zero |
| 1.5 MP landscape with scanner, repeat RGB-stage reuse | 73.59 ms | 20.95 ms | Zero |
| 6 MP portrait with halation, cache disabled | 605.80 ms | 511.12 ms | Max relative 0.017954; RMS 0.00001980 |

These are specific fixtures, not a guarantee across GPUs or settings. Cache hits
require unchanged upstream stages; first renders can cost more because they
compile helper pipelines and populate cache buffers. These gains do not multiply.

Fast halation is saved per photo (values.fastSpatial). Broad tails/bounces use
half-resolution GPU buffers and the original physics kernels with doubled
physical pixel size. Fine scatter core remains full-size. Narrow blur radii and
radii that would change the original 256-pixel support cap use the original GPU
kernels. A 25-case odd-width matrix passed max relative 0.00005293 and RMS
0.00000109. This mode is opt-in, since small edge differences remain.

During interaction, the transient look uses preview grain without changing the
saved/export grain model. Halation/diffusion/scanner effects remain enabled;
only broad halation and DIR diffusion receive the documented interactive shortcut.

Rejected candidates: reduced camera diffusion (max relative error 0.0573),
reduced print diffusion (0.0364), and alternate scanner MPS blur (changed alpha
without a worthwhile speed gain). Their optimization code was removed; original
GPU kernels and exact stage caching are used instead. Spectral LUTs remain
experimental and disabled in application exports because they were slower.

Build provenance: build_app.sh fingerprints both native archives and forces a
fresh product link when they change. A native-only update produced an explicit
Linking step (2.40 s), avoiding stale SwiftPM products linked via external flags.
