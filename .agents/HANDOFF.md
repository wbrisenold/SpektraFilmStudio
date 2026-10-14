# Handoff — SpektraFilmStudio

Written at end of session. Read this before touching the repo.

## Repo state (critical)

`HEAD = a4499b3 "update"` — **pushed? NO. Compiles? NO.**

`a4499b3` was committed from the git *index* while the working tree carried
uncommitted fixes, so it captured a **broken** `AppModel.swift` (line 431 is
whitespace where `    }` must be). A `git checkout a4499b3` will not build.

The working tree DOES build — `swift build` exit 0, **0 errors, 0 warnings**.
**Commit from the working tree, not from `a4499b3`.**

## P0 — EXPORT FAILS ON EVERY REAL PHOTO. Root cause found, unfixed.

Reproduced with a real file:

```
/Users/A1990/Pictures/Exports/from C1 to LR/0K8A1468.CR3
Canon EOS R5 C · 8192x5464 (44.8 MP) · 103 MB

ORIGINAL_EXPORT_FAIL: "Render failed: Caused GPU Timeout Error
                       (00000002:kIOAccelCommandBufferCallbackErrorTimeout)"
```

**Metal command-buffer timeout.** The host GPU is Intel UHD 630 (2019
i7-9750H). One command buffer carrying the whole print-sim render of a 45 MP
frame exceeds the GPU watchdog; the driver kills it.

Fails every photo at every size because it scales with pixel count x passes per
submission. Every R5/R6 body is ~45 MP. Small fixtures pass (8x8, 160x106).

**Fix direction: chunk the render across multiple command buffers.** Bound the
work per submission. Do NOT "fix" the dimension guard — that was a red herring.

**Before writing it:** confirm the hypothesis on a second real file and measure
the pass count. A wrong fix risks silent partial renders.

Real raw files for testing (7):
`~/Pictures/2024/03-10/R6__4387.CR3`, `R6__4380.CR3`,
`~/Pictures/Raws/0K8A6799.CR3`, `~/Pictures/2023/12-22/R6__8483.CR3`,
`R6__8517.CR3`, `~/Pictures/2023/11-12/R6__3339.CR3`.

## Second failing gate — GPU parity (still red)

```
SELFTEST FAIL: Fused GPU host/film parity failed: worst rel err 0.2609
gpu=0.5998856 ref=0.86078376  exposureEV=0 contrast=0 ... autoContrast=true
```

Cause: GPU and CPU implement auto-contrast **differently**.
- GPU (`AutoContrastMath.bounds`, ToneGradeEngine.swift:767): 16384-bin
  histogram, clamped **linear** luma, Rec.709 (0.2627/0.6780/0.0593),
  first/last bin with count > 1.
- CPU (`referenceFilmExposureShape`, FilmExposureShaper.swift:20-38):
  **log2** luma, sorted 2%/98% percentiles, gate `hi-lo > 0.5`.

Different domain (linear vs log2). Not a tolerance issue.

**User decision: keep the GPU (faster) and rewrite the CPU reference to match
`AutoContrastMath.bounds`.** Not started.

## Why there are no live slider edits — premise corrected

`Native/src/SpektraMetalRenderer.mm:4574`:

```cpp
const bool cacheEligible = impl_->stageCacheEnabled && finalPrintSimulation && ...
```

`finalPrintSimulation = finalOutput && process == ProcessMode::PrintSimulation`
(:4046). **The stage cache is export-only by construction** — unreachable from
the interactive path. That is the whole cause; not a tuning issue.

`:4579` additionally `memcmp`s the **entire source buffer**. Do NOT remove it:
`cachedFilmDensity` (:2730) and `cachedScannerInput` (:2728) are full-frame
*pixel-derived* planes, and `filmStageSource` (:2729) is a CPU shadow copy kept
only for that memcmp. A params-only key would return a plane built from different
pixels — silent colour corruption. The memcmp is also ~38 ms for 384 MB, i.e.
not the bottleneck.

Lightamer's two ideas are therefore moot as stated: there are no four pipes, and
no per-layer cache lines to namespace. The real work is per-stage cache lines
keyed on own-params + upstream hash, Darktable-style.

**Before widening `cacheEligible`**, audit the many sites that clear the keys:
:3051, :4763, :4947, :5471, :6601, :6628 — or the cache will thrash.

Also: the `PREFIX HASH DIRTY TAIL PASS: stable, suffix-blind` self-test does NOT
exercise this code. That property must live in the AppModel preview cache.
Worth confirming — you may believe you have prefix invalidation and you don't.

## Removed this session (working tree, uncommitted)

- `Sources/SpektraFilmFast/ToneMapping/` — 7 files, 68 KB, fully orphaned.
  `SkiaToneModules.swift` dropped from two hardcoded lists in
  `scripts/verify_source.sh`.
- Tone stages `.sigmoid` / `.agx` / `.filmicRGB` from `PipeStage`;
  `ToneEngineSelection`; `PipeSettings.sigmoid/agx/filmicRGB/toneEngine`;
  `selectTone`; `AppModel.setPipeToneEngine`; the tone param-slider views and
  the tone-engine picker; the tone dispatch block in `GPULiveFramePipeline`.
- `PipeSettings` gained a custom `init(from:)` that **drops unknown stage keys**
  — old projects carry `"sigmoid"` in `[PipeStage: Bool]`, which a synthesized
  decoder rejects. Back-compat is deliberate; keep it.
- `ImageDecoder`: degenerate extent now reports "could not be decoded by macOS"
  instead of the false "exceeds safe decoding memory limit".

## Still to do

- **Delete `GPULiveFramePipeline`** (user: "a failed project, make it
  disappear") — 69 refs across 14 files, 554 lines. Reaches
  `StudioImportCalibration`, `MetalPreviewCanvas`, `ImageDecoder`, self-tests.
  Big and order-sensitive; do it in its own session.
- `verify_source.sh` **failed after manifest regeneration** (309 files).
  Cause undiagnosed. Run it directly.
- No gates have passed. No commit. No push.

### `verify_source.sh` failure — DIAGNOSED, pre-existing gate rot

```
Sources/SpektraFilmFast/StudioOmniSearch.swift:172: error: cannot find 'StudioPalette' in scope
```

Cause: `scripts/verify_source.sh` runs `swiftc -frontend -parse` over a
**hardcoded file list** (two copies, ~28 and ~31). That list is missing
`Sources/SpektraFilmFast/StudioUI.swift`, which is where `StudioPalette` is
defined. So the parse gate cannot resolve it.

This is **not** caused by the tone removal — `StudioUI.swift` was never in the
list, so this gate has been failing since that file was added. `swift build` is
unaffected because SwiftPM globs the whole directory; only the gate's list is
stale.

Same trap: the list also references `GPULiveFramePipeline.swift` and
`Modules/WorkflowDefaults.swift`, so it must be updated when files are removed.

**Recommended fix (removes the whole class of rot):** replace both hardcoded
lists with a filesystem glob, e.g.
`mapfile -t FILES < <(find Sources/SpektraFilmFast -name '*.swift' | sort)`,
and keep any per-file compiler flags in a separate variable. Do not hand-edit
the list again.

## Harness built (use these)

```bash
# real RAW -> export, headless
./dist/SpektraFilmStudio.app/Contents/MacOS/SpektraFilmStudio \
  --export-smoke-test --export-fixture "<raw>" --export-output /tmp/out
# other modes: --self-test --render-integrity-test --studio-soak-test
./tests/fixtures/fetch_raw_fixtures.sh      # 12 exiftool fixtures (some truncated)
./scripts/regen_repomix.sh                  # idempotent repack
./scripts/refresh_source_manifest.sh        # regen + self-verify
./scripts/install_repomix_hooks.sh          # pre-commit/pre-push repack
```

Gotcha: bare `.build/debug/...` cannot run — missing onnxruntime rpath. Use the
`dist/*.app` binary. No Xcode here (Command Line Tools only): no `swiftlint`,
no `xcodebuild`, no `xctrace`/Instruments, no `metal` compiler. `swift format
lint` is the lint tool and works.

All Metal shaders compile at runtime via `device.makeLibrary(source:)`, so
Metal itself is the only validator. See `.agents/skills/metal-shaders/SKILL.md`.

## Decisions on record

- **Lightamer** (`kamasylvia/Lightamer`) is MIT and reusable but 0 stars,
  2 weeks old, Tuist — do not adopt wholesale. We already hand-ported its tone
  modules and that port is what broke parity. Vendor verbatim or not at all.
- **`JanLohse/spectral_film_lut`** — MIT, 111 stars, actively maintained,
  generates film LUTs from datasheets. A tool, not a port, so no parity risk.
  Best-value lead. Not adopted.
- **`LightamerCore/Sources/Export`** (16 files) is worth reading against the P0.