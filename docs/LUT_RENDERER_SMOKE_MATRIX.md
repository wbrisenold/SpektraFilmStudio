# Native LUT smoke and renderer regression matrix

Baseline `wbrisenold/SpektraFilmStudio@cbe9033e0ba4e70340dadf03f2d5ef5c08ccd76b`.

## Commands

On the Intel Mac, extract the kit and run `SPEKTRA_BUILD=1 ./RUN_ON_MAC.command`. The installer creates a **separate baseline**, clones and checks the pinned source commit, applies patches with strict blob/anchor checks, then builds and executes:

`OUTPUT/SpektraFilmStudio-LUT-SmartCatalog-RendererGate-cbe9033e/scripts/run_lut_smoke.sh`

You may rerun that script later after building the app. The file is installed into the patched checkout. A nonzero exit code **blocks success**; do not mark a failed smoke as passed.

## Local smoke (already run in this kit)

- `python3 -m unittest discover -s tests -p 'test_*.py' -v`: 12 unit/static tests, including synthetic source-anchor transforms.
- `swiftc Sources/StudioLUTCatalog.swift tests/catalog_smoke.swift -o /tmp/lut-catalog-smoke && /tmp/lut-catalog-smoke`: real Swift execution with CSV BOM, quoted commas, escaped quotes, relative paths and film/paper/stage names.
- `swiftc -frontend -parse` validates package Swift files. This is *not* a Swift typecheck of the full macOS project.

## Mac app smoke (`--lut-smoke-test`, bundled in app)

1. Creates temporary known `.cube` files; no original RAW photographs or actual user LUTs touched.
2. CSV index builds friendly labels, not the filesystem basename.
3. Metal lookup of sRGB→sRGB identity cube produces expected gamma-encoded neutral and alpha.
4. Reuse same `.cube` twice: **exactly one GPU texture upload**, at least one cache hit, exact repeat pixel data.
5. A signed-log Rec.2020 cube built on the correct inverse shaper produces finite pixels close to the sRGB-reference output.
6. Invalid `.cube` is **rejected** rather than silently replaced by native film.
7. Built-in 33³ LUT: disables spatial DIR via `fastDIR`, prepares the actual film GPU bake, confirms `settledCachedFilmLUT` processes pixels, modifies RAW exposure and host tone, and verifies the cache signature remains unchanged, `prewarmLUT` returns `.inMemory`, and settled LUT pixel output is identical.
8. `rendererPathStatus` is published by the **settled** LUT stage; a request that cannot use a generated LUT is labelled as native with the reason preserved in Settings. Imported LUT selection never calls the internal baker.

**Still needed before production release:** exercise this smoke on actual Intel Radeon hardware, compare displayed settled frames with final written JPEG/TIFF, test real image captures (CR3/RAF/ARW), verify actual film and output color accuracy, and validate crash/reopen state. This kit cannot complete those checks in the Linux container.

## Expected terminal markers

`CATALOG_SMOKE_PASS: ...` and `LUT_SMOKE_PASS: ...`, followed by `PASS: LUT smart catalog...`.

Anything else, including app startup timeout, compilation errors, or the native eligibility gate rejecting a look, is a **failed/unverified release**. Preserve and share the terminal log for investigation.

## Known limits

- Imported `.cube` 3D only; separate OCIO, CLF, `.3dl`, complex 1D+3D chain import is not implemented in this patch.
- Existing exported `.cube` files without a contract remain **assumed sRGB→sRGB**. A new scene-linear `.cube` requires the exact `signed-log2-v1` sampling grid and sidecar.
- Scene-linear full-film LUT input is not automatically enabled in the upstream Python generator; this kit does not rewrite your existing sRGB assets.
- Cached internal color-only LUT **cannot** represent film grain, halation, spatial DIR diffusion, spatial scanner, or image-wide statistics. Those looks will correctly use the native simulator unless the effects are managed in separate stages.
- The existing settled preview pipeline still uses CPU-backed output for masks and geometry. The kit does not eliminate all CPU transfers.
- Imported LUT selection is app-wide and isn't stored per export job; don't switch LUTs mid-job.
