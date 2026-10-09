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
