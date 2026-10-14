---
name: metal-shaders
description: Write, debug and ship Metal shaders in SpektraFilmStudio. Use when adding or changing a .metal kernel, a GPU engine (GPUHostGradeEngine, GPULiveFramePipeline, MaskMetalEngine, RedlampFilmEffectsEngine, MetalExportResizer, StudioImportCalibration, StudioLinear2020ToSRGB, StudioMetalGeometry, LensCharacterEngine), any `device.makeLibrary(source:)`, or when a GPU path returns wrong pixels or aborts with an MTLCommandBuffer assertion. Covers runtime kernel compilation, command-buffer lifecycle, CPU/GPU parity gates, and DCTL debugging.
---

# Metal shaders in SpektraFilmStudio

## How kernels actually compile here

Every kernel is an **inline Swift string** compiled at runtime:

```swift
let library = try device.makeLibrary(source: source, options: nil)
```

There is no `metal` compiler on the build machine (Command Line Tools only, no
Xcode.app), so `xcrun metal` is unavailable and `Resources/SpektraFilm.metallib`
is a legacy bundle artifact. `makeLibrary(source:)` is the **only** validator.
`dctlw` is not installed and would be too lenient anyway — Metal's own compiler
is the only valid test.

Grep the new kernel with `rg -n 'addCompletedHandler' Sources/SpektraFilmFast/`
before shipping; every GPU path must be re-checked against the lifecycle rules below.

## Command-buffer lifecycle (source of real SIGABRTs)

`-[_MTLCommandBuffer addCompletedHandler:]: failed assertion 'Completed handler
provided after commit call'` aborts the process with exit 134. Rules:

- **Sync function that reads the output buffer** → `commit()` then
  `waitUntilCompleted()`, then `guard command.status == .completed`.
- **Async function** → register `addCompletedHandler` **before** `commit()`, inside
  the continuation:

  ```swift
  encoder.endEncoding()
  await withCheckedContinuation { continuation in
      command.addCompletedHandler { _ in continuation.resume() }
      command.commit()
  }
  ```

Never read `buffer.contents()` after a bare `commit()`. That returns whatever the
GPU has written so far — it looks like it works on a 128×64 test buffer and
produces garbage on a full-resolution frame. The parity test is sized small
enough to hide this, which is why `GPUGradeRegressionTests` must be read as a
correctness gate and not a smoke test.

If a `commit()`-then-read path is only there for performance, use the `…Async`
variant already on the engine instead of removing the wait.

## CPU/GPU parity gates

`Sources/SpektraFilmFast/GPUGradeRegressionTests.swift` compares every GPU path
against a CPU reference (`referenceHostGrade`, `referenceFilmExposureShape`).
A GPU change is not done until `SpektraFilmStudio --self-test` exits 0.

When it fails, the error string carries worst relative error, both sample values
and the ToneSettings under test — read it before touching the shader.

- `Fused GPU host/film parity failed` → `applyingHostAndFilmGrade` (the fused
  single-pass path) disagrees with host-then-film staged.
- `GPU tone parity failed` → `applyingHostGrade` disagrees with `referenceHostGrade`.
- `GPU film-input parity failed` → `applyingFilmExposureShape` disagrees with
  `referenceFilmExposureShape`.

Note `applyingHostAndFilmGrade` deliberately routes `film.autoContrast == true`
through the **staged** path, not the fused one. That branch is why a divergence
can appear only for auto-contrast.

## Buffers and precision

- Shared-storage buffers are read straight after the wait; no extra copy needed.
- `PixelBufferF32` is RGBA float — `pixels.count == width * height * 4`. Guard on
  that invariant; a mismatch surfaces as an opaque Metal crash, not a Swift error.
- Shaders use `float` (fp32) throughout. The parity threshold is `3e-4` relative;
  anything near that is a precision bug, not a tolerance to widen.
- Keep pass-through guards first: identity tone/density must return the input
  untouched before any allocation or dispatch.

## DCTL debugging (Resolve / OFX path)

For `.dctl` files rather than this app's inline kernels:

- `DCTLUI_COMBO_BOX` value lists must be **C identifiers**, never integers:
  correct `{expMult, expAdd}`, wrong `{1,2,3}` (the preprocessor expands the
  integers as standalone statements → "expected identifier").
- Combo values start at 0; first option = 0.
- `_mix` argument order decides where the effect lands — zone 0 (shadows) needs
  the effect at the lowest values, zones 1-2 need it at weight peak.
- Real errors land in
  `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Logs/davinci_resolve.log`,
  not in `dctlw` output.
- Install OFX bundles to `/Library/OFX/Plugins/` (system path, root-owned),
  never `~/Library/OFX/Plugins/`.