# Phase 1: Live-Edit Hardening + Auto Calibration UI

Design: `docs/superpowers/specs/2026-10-10-darktable-live-edit-auto-calibration-design.md` (approved).
Scope: interactive/proxy path only. Export/full-res paths unchanged except where they already call the same resolve-once helper.

## Constraints

- Ponytail: smallest change that fully works. No new dependencies. No layout redesign (StudioPalette/StudioLayout tokens only).
- `AppModel` stays single `ObservableObject` hub.
- After any source edit: `scripts/verify_source.sh`, VERSION bump if shipping, SOURCE_MANIFEST regen.
- Tests live in in-app smoke suites (`--self-test` / `--lut-smoke-test`), not SPM.
- Auto Exposure target = `RawSettings.developExposureEV` (darktable `iop/exposure` stage), not `ToneSettings.exposureEV` / `filmExposureEv` / `hdrExposureEv`.
- Auto flags stay in the look for UI; render paths consume pre-resolved concrete values. Manual slider drag clears the auto-was-applied marker for that param only.
- Legacy `.spektrafilm` with auto flags but no resolved values → resolve once on first render on the proxy/gesture baseline buffer.

## Architecture

```
ControlsView "Auto Exposure" / "Auto Contrast" / "Auto WB" buttons
        │
        ▼
AppModel.resolveAutoOnce(parameter:)  ──►  AutoCalibrationMath (pure)
        │                                      │
        │                                      ├─ exposurePercentiles → developExposureEV
        │                                      ├─ AutoContrastMath.bounds → resolvedBlack/White
        │                                      └─ applyingAutoWhiteBalance → temperature/tint
        ▼
ToneSettings.resolvedAutoContrastBlack/White  (new optional fields)
RawSettings.resolvedAutoExposure  (new Bool marker; EV written to developExposureEV)
renderLook copy for GPU/native: auto flags false, resolved fields set
        │
        ▼
beginEditGesture / mutateRawDevelop(interactive:true)
  → if auto flags set and not yet resolved → resolve once on gesture baseline
  → GPUHostGradeEngine.encode uses resolved bounds (no throw)
  → GPULiveFramePipeline.supports returns true when resolved
  → NativeRenderer.colorLUTBlockingReason: autoExposure resolved → no block
```

Prefix-hash dirty-tail (interactive only): hash stable look-field prefix; on suffix-only change reuse prior scratch/stage buffers without re-running independent stages. Full-res export path keeps existing ≤128MB stage cache (no change).

## Tasks

### Task 1 — AutoCalibrationMath pure helpers

**Files**
- New: `Sources/SpektraFilmFast/AutoCalibrationMath.swift`
- New: `Sources/SpektraFilmFast/AutoCalibrationMathSmoke.swift` (or append to `GPUGradeRegressionTests.swift`)

**Steps**
1. Write failing smoke checks (run via `--self-test` entry):
   - Flat mid-gray buffer → developExposureEV delta near 0.
   - Dark ramp (all values < 0.1 linear) → positive EV.
   - Blown ramp (all values > 0.9) → negative EV.
   - `AutoContrastMath.bounds` on known black/white ramp → within expected pair.
2. Implement `enum AutoCalibrationMath`:
   - `static func developExposureEV(pixels: [Float]) -> Double` — sample luma percentiles (reuse `StudioImportCalibrationEstimator` pattern: bounded lattice, ignore single-count bins like `AutoContrastMath.bounds`). Target mid-gray ≈ 0.18 linear. Clamp result to ±3 EV so a click cannot slam the RAW exposure slider to its ±5 EV edge without user intent.
   - `static func resolveContrast(pixels: [Float]) -> (black: Double, white: Double)?` — thin wrapper over `AutoContrastMath.bounds`.
   - `static func whiteBalance(pixels: [Float], width: Int, height: Int) -> (temperature: Double, tint: Double)?` — wraps `PixelBufferF32.applyingAutoWhiteBalance()` logic without mutating; returns the offsets the UI would apply.
3. Smoke test asserts finite values, expected sign, and idempotence (same buffer → same result).

**Done when** `--self-test` includes and passes the new checks; no UI yet.

---

### Task 2 — Resolve-once state on ToneSettings / RawSettings

**Files**
- `Sources/SpektraFilmFast/ProjectModels.swift` (`ToneSettings`, `RawSettings`)
- `Sources/SpektraFilmFast/AutoCalibrationMath.swift` (if resolve helpers live here)

**Steps**
1. Add to `ToneSettings`:
   - `var resolvedAutoContrastBlack: Double?`
   - `var resolvedAutoContrastWhite: Double?`
   - Defaults `nil` so existing projects and encode paths that ignore them are unchanged.
2. Add to `RawSettings`:
   - `var autoExposureApplied: Bool = false` — UI “last was auto” marker only.
   - No separate EV field: the EV lives in existing `developExposureEV`.
3. Add pure helpers (no AppModel yet):
   - `func applyingResolvedAutoContrast(bounds:) -> ToneSettings` — sets resolved fields, leaves `autoContrast` true for UI.
   - `func isAutoContrastResolved -> Bool` — true when both resolved fields non-nil.
   - `func clearingAutoContrast() -> ToneSettings` — manual drag path: `autoContrast = false`, nil out resolved fields.
4. Extend `GPUGradeRegressionTests` with encode/apply parity: same input, autoContrast with pre-resolved bounds vs explicit `AutoContrastMath.apply` → error below existing threshold.

**Done when** parity test passes; no callers switched yet.

---

### Task 3 — GPU fast path accepts resolved auto

**Files**
- `Sources/SpektraFilmFast/GPUHostGradeEngine.swift`
- `Sources/SpektraFilmFast/GPULiveFramePipeline.swift`
- `Sources/SpektraFilmFast/NativeRenderer.swift` (colorLUT blocking only)

**Steps**
1. `GPUHostGradeEngine.encode`:
   - Replace the blanket `guard !t.autoContrast && !f.autoContrast` throw with: if `autoContrast` and resolved fields present on `tone`, pass those bounds into params[12]/params[13] instead of throwing. If unresolved, keep the existing throw (legacy path still forces CPU `apply` or resolve-once).
2. `GPULiveFramePipeline.supports` and `render(url:look:…)`:
   - Stop throwing when `tone.autoContrast == true` **and** resolved fields are non-nil. Keep the throw for unresolved auto (legacy first-frame).
3. `NativeRenderer.colorLUTBlockingReason`:
   - If `params.autoExposure` is set but the look already has `raw.autoExposureApplied` and the EV was baked into `developExposureEV` at gesture start, do **not** block. Keep block for unresolved native autoExposure (unknown legacy state).
4. Regression: `GPUGradeRegressionTests` case that previously expected unsupported autoContrast on encode now succeeds when resolved; unresolved still fails with the same error string.

**Done when** all three gates above pass resolved-auto cases and still fail unresolved ones.

---

### Task 4 — AppModel resolve-once at gesture begin + auto button actions

**Files**
- `Sources/SpektraFilmFast/AppModel.swift`
- `Sources/SpektraFilmFast/InteractivePreviewProxy.swift` (only if proxy needs the resolved copy)

**Steps**
1. Add `func resolveAutoOnce(changedParameter: String?, in buffer: PixelBufferF32) -> RenderLook`:
   - If `changedParameter` is the auto-exposure button path or look has unresolved native `autoExposure`: run `AutoCalibrationMath.developExposureEV`, write to `raw.developExposureEV`, set `raw.autoExposureApplied = true`, clear native `autoExposure` value flag so the render path is fully concrete.
   - If `tone.autoContrast` (or `filmTone.autoContrast`) and not resolved: run `resolveContrast`, store into `resolvedAutoContrastBlack/White`, keep `autoContrast = true` for UI.
   - If auto-WB button path: run WB math, write `whiteBalanceMode = .custom` + temperature/tint (or offset path if that is what `applyingAutoWhiteBalance` already mutates).
2. Call it from `beginEditGesture()` **after** freezing `gestureSettleBaselineBuffer` / `gestureBaselineRenderedBuffer`, on the smaller of the two buffers (proxy-sized). Never block the gesture on full-res.
3. Call it from `mutateTone(interactive:true, changedParameter: "hostAutoContrast")` and from new `setRawDevelopAutoExposure()` / WB button entry points: one meter, then treat as a normal interactive edit.
4. Manual-drag clear: in the existing tone/raw setters that already clear `tone.autoContrast` for non-host changes, also call `clearingAutoContrast()` so resolved fields go nil and the next gesture re-meters if the user re-enables auto.
5. `recalculateAutoWhiteBalance()` stays as-is for `.auto` WB mode; the new button is for explicit one-shot on any photo (including already-custom WB).

**Done when** `--ux-smoke-test` (or a focused self-test section) drives: open photo → press Auto Exposure → `developExposureEV` changes once, `autoExposureApplied` true, second press is a no-op unless buffer changed. No per-frame re-meter logs.

---

### Task 5 — ControlsView Auto buttons + readouts

**Files**
- `Sources/SpektraFilmFast/ControlsView.swift` (Camera development / rawSection)

**Steps**
1. In `rawSection` near the existing Exposure slider (`openAdjustment = "tone"` button row):
   - `Button("Auto Exposure") { model.setRawDevelopAutoExposure() }` — disabled while `model.raw.developExposureEV` is mid-drag if that state is already tracked; otherwise always enabled.
   - Readout: small Text showing last auto EV when `autoExposureApplied` (e.g. `Auto +0.42 EV`), else nothing.
2. In tone section near contrast:
   - `Button("Auto Contrast") { model.setAutoContrast(interactive: false) }` + resolved-bounds readout when present.
3. Near WB picker:
   - `Button("Auto WB") { model.setAutoWhiteBalanceOnce() }` + readout of applied temperature/tint when last action was auto.
4. Buttons use existing `DesignToken` / `StudioLayout` spacing only. No new palette colors.
5. Wire into `StudioUXSmokeTest` if that suite already walks Camera development; otherwise a self-test assertion that the buttons exist on the live view hierarchy is enough.

**Done when** app builds; three buttons visible in Camera development / Light; each writes concrete params and updates its readout.

---

### Task 6 — Prefix-hash dirty-tail cache (interactive path only)

**Files**
- `Sources/SpektraFilmFast/AppModel.swift` (`scheduleRender`, `publishInteractiveProxy`)
- Possibly `Sources/SpektraFilmFast/NativeRenderer.swift` (stage cache key extension) — only if prefix hash can piggyback existing stage cache without new subsystems

**Steps**
1. Define `static func prefixHash(look: RenderLook, independentPrefixFields: Set<String>) -> UInt64` — stable hash over the fields that feed independent stages (raw/WB, import LUT, film core, etc.). Exclude fields after the edit boundary (tone curve points the user is dragging, etc.).
2. On interactive render only: if prefixHash matches last interactive render **and** only suffix fields changed, skip re-encoding independent Metal stages and reuse the prior scratch buffers (existing scratch pool in `GPULiveFramePipeline`).
3. Do **not** touch full-res export stage cache (≤128MB budget) or scanner path.
4. Smoke: two interactive renders with identical prefix + different tone → second pass reports stage-cache hit count increase (mirror `STAGE CACHE / INTERACTIVE GRAIN PASS` pattern in ProductionSelfTest). Different prefix → full re-run.

**Done when** hit/miss counts match expectations in `--self-test`; no visual change on a known A/B pair (reuse existing GPU regression fixtures).

---

### Task 7 — Legacy resolve-on-first-render

**Files**
- `Sources/SpektraFilmFast/AppModel.swift` (load / first scheduleRender)

**Steps**
1. On project load or first `scheduleRender` after open: if look has `tone.autoContrast == true` and resolved fields nil, or native `autoExposure` true with no `autoExposureApplied`, call `resolveAutoOnce` on the current proxy/gesture baseline (or a one-shot downsample if none). Persist resolved values into the in-memory look (not necessarily re-save the file until next save).
2. Smoke: craft a minimal JSON look with auto flags only → load → render → resolved fields non-nil, no crash, no block.

**Done when** synthetic legacy project self-test passes.

---

### Task 8 — Ship discipline

**Steps**
1. `scripts/verify_source.sh` after every Task 1–7 source edit.
2. Full `swift build` clean (0 errors; keep 0 warnings if already clean).
3. `scripts/qa_production.py` green.
4. Bump `VERSION` once for the release that ships Phase 1.
5. Regen `SOURCE_MANIFEST.sha256`.
6. Do **not** upload/release unless user asks (patch-pipeline upload still detached if needed).

**Done when** local QA + manifest regenerate cleanly; no branding/QA pin strings touched.

## Out of scope (do not implement here)

- Tone equalizer, color equalizer, color balance RGB, graduated ND, vignette/bloom UI
- Filmic/sigmoid, diffuse blur, keystone, lens correction
- Denoise beyond current RawForge path
- Parametric masks, retouch/heal
- Full-res export prefix-hash (export keeps existing stage cache)
- Per-render auto re-meter of any kind

## Key existing symbols (do not reinvent)

| Need | Symbol | File |
|------|--------|------|
| Contrast bounds | `AutoContrastMath.bounds/apply` | ToneGradeEngine.swift:760 |
| WB solve | `PixelBufferF32.applyingAutoWhiteBalance()` | AutoWhiteBalance.swift:8 |
| Percentile precedent | `StudioImportCalibrationEstimator.estimate` | StudioImportCalibration.swift:88 |
| Gesture baseline freeze | `beginEditGesture` / `endEditGesture` | AppModel.swift:1279 / 1304 |
| Interactive mutate | `mutateRawDevelop` / `mutateTone` | AppModel.swift:2651 / 2886 |
| GPU support gate | `GPULiveFramePipeline.supports` | GPULiveFramePipeline.swift:190 |
| Encode auto block | `GPUHostGradeEngine.encode` | GPUHostGradeEngine.swift:29 |
| LUT blocking | `NativeRenderer.colorLUTBlockingReason` | NativeRenderer.swift:246 |
| RAW exposure write | `RawSettings.developExposureEV` | ProjectModels.swift:243 |
| Smoke harness pattern | `GPUGradeRegressionTests.run` / `StudioLooksSmokeSuite` | in Sources |

## Risks

- **Wrong exposure target**: writing auto to film/hdr exposure instead of `developExposureEV` makes auto useless on RAW. Mitigation: Task 4 tests assert the RAW slider moves.
- **Re-introducing per-frame meter**: any resolve inside the render loop reintroduces latency. Mitigation: resolve only in `beginEditGesture` / button actions; encode paths never call `AutoCalibrationMath`.
- **Legacy projects**: unresolved auto still blocks GPU; first open must resolve or user sees CPU path once. Acceptable and designed.
- **Prefix-hash incorrectness**: over-broad prefix reuse shows stale independent stages. Mitigation: hash includes every field feeding independent stages; start with a conservative field set and expand only after A/B fixtures match.
- **QA pin strings**: never touch `SpektraFilm.icns`, `CFBundleIconName`, `"SpektraFilmFast Cache"`, `"func resetLook()"`, `'Label("Reset All"'`, stock path strings.

## Next after Phase 1

Phase 2 (separate plans): tone equalizer, color equalizer, color balance RGB, graduated ND, vignette/bloom UI — same one-shot auto discipline, no per-render analysis.
