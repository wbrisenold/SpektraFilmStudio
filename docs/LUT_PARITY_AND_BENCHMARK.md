# LUT review gate — SpektraFilm Studio (October 10, 2026)

**Rule:** Do not replace the native exact film renderer or enable LUT by default until real-hardware parity, performance and UX gates pass. Do not assume ART's separate Spectral Film LUT represents the same film science as the SpektraFilm model.

## Two experiments

| Candidate | What it models | Input/output | Compare against |
| --- | --- | --- | --- |
| Studio whole-film 33³/65³ LUT | Existing Spektra native non-spatial film & print in current look | signed logarithmic **linear Rec.2020** -> native output color role | current native exact film render of the **same** saved look |
| ART Spectral Film LUT 33³ | Different Jan Lohse datasheet-based film & print model | ART's ACES matrices, camera-linear-to-log, CLF tetrahedral LUT | ART's own preview/output; creative comparison with Studio **only after** color transforms are matched |

ART's Spectral Film LUT 33³ generator is at `tools/extlut/spectral_film_mklut.py`, not the SpektraFilm creator in `tools/extlut/spektrafilm_mklut.py`. ART emits the whole CLF process (matrix -> Log -> LUT3D). Stripping the shaper/matrix or treating it as an sRGB .cube causes invalid comparisons.

## Test matrix on an Intel Radeon Mac

1. Pin source SHA 60c7f467, build `SPEKTRA_BUILD=1`, run source/10-pass QA and full `--self-test` / rendering smoke if provided by the app.
2. Use RAW files with known working space: well-exposed portrait skin, bright white fabric, saturated reds/blues, deep shadows, underexposed and HDR-overrange material, and monochrome neutral patches.
3. For SAME film+paper/color look with **all spatial modes disabled**, measure median of ≥30 settled Native previews; then select 33³, wait for its cold LUT bake, measure ≥30 warm edits; repeat 65³. Log cold bake separately from warm lookup; include first-use shader compilation cost.
4. Capture native and LUT **linear float output before monitor display transform** using a dedicated diagnostic capture, then calculate RMS/max channel errors, ΔE00, and exact clipping/skin-scope agreement. Do not compare screen-grab PNG as a substitute for float-output parity.
5. Suggested *acceptance target*, NOT a passing result: max rel error <= 0.002, RMS <= 0.0001 on in-domain samples; no perceptually obvious patch artifacts or hue shifts; 95th-percentile warm latency lower than native; no more than one pending GPU frame; no negative/HDR out-of-domain clipping.
6. Turn on halation, DIR spatial diffusion, grain, camera/print diffusion, scanner blur or Auto Exposure: check that renderer declines LUT and produces same native result with all effects still active. Confirm exact JPEG/TIFF/HEIC export remains bit-identical with LUT UI mode switched on/off.
7. Reuse exact film+paper look across several photos/host-tone edits: LUT cache should be hit with no rebake. Change film stock, printer lights, gamma, exposure, or color pipeline: cache must miss/invalidate and bake new table.
8. Verify 33³ and 65³ LUT texture memory and stability on Intel Radeon Pro 555X; test hidden/visible scopes and the preserved Redlamp slider geometry.
9. Run ART `try_art_spectral_film_lut.command`, validate generated `CLF` and metadata; show same calibrated scene-linear test images through an OCIO-aware host with the upstream CLF. Only then compare appearance and generation time. No numerical parity assumption across two different models.
10. Reject LUT-default promotion unless tests pass. The present code is a guarded experiment, not a measured performance breakthrough.

## Existing baseline (different technology!)

The project's `docs/RENDERING_RESEARCH.md` reports Radeon Pro 555X tests for an **internal density-stage LUT**, not the ART-style whole-film LUT: native full spatial DIR 145.15ms vs density LUT 275.74ms, and native nonspatial DIR 75.70ms vs density LUT 156.86ms. That negative result does not prove the new whole-film LUT is slower. It justifies an honest A/B test.

## Out-of-domain and color limits

The candidate input shaper covers [-2, 64] scene-linear per channel. Out-of-domain values are clamped in *live-preview LUT mode only*. They can differ from exact highlights/shadows and must fail a strict parity gate on affected images; exact exports and native previews remain available. LUT interpolation is an approximation even within range, and separate scanner/spatial effects cannot be baked into a 3D color-only lookup.
