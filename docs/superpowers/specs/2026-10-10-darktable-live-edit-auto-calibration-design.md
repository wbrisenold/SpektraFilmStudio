# Darktable-parity: live editing + auto calibration + develop operators

Status: design for approval. No product code until the human partner approves this document.

## Intent

Port three things from darktable into SpektraFilmStudio, in the order that matters to the user:

1. **Live interactive editing** — adjusting a control feels immediate (darktable-style dirty-tail recompute + low-res interactive viewport), not "wait for a full re-render."
2. **Auto calibration in the UI** — one-shot Auto Exposure, Auto Contrast, and Auto White Balance (plus Auto Baseline) with visible readouts and buttons in the edit inspector, like darktable's auto levels/exposure/WB.
3. **Develop operators 1–12** (the earlier gap list): parametric masks, tone equalizer, color equalizer, filmic/sigmoid alternatives, color balance RGB, live pipeline itself (this doc's phase 1), diffuse/guided blur, NLM/wavelet-class denoise, ashift keystone, lens correction, retouch/heal, graduated ND + vignette + bloom.

Spektra already has most of the live-edit *plumbing*; this is mostly finishing/hardening, wiring dead UI, and new operators — not a from-scratch renderer rewrite.

## Why now

The user judges the app by how photos look on first open (auto look) and how it *feels* while dragging sliders. Missing auto-contrast UI and auto features that disable the GPU fast path are the concrete gaps. Operators 2–12 add darktable-class grading power after that foundation is solid.

## Goals

- Slider drags stay interactive: interactive proxy path stays on during gestures involving auto parameters (today `autoExposure` and `autoContrast` force the exact/slow path).
- Auto Exposure / Auto Contrast / Auto WB each have a visible control (button + applied-value readout) in the RAW/Light inspector; one click applies parameters through the normal look-parameter pipeline (undoable, persisted in `.spektrafilm`).
- Auto analysis runs on the cheap path (existing proxy-resolution buffers / decode histograms), never on full-res export resolution.
- Interactive viewport follows darktable's proven model where Spektra lacks it: coalesce param writes per display tick, latest-render-wins with abort, one interactive working resolution (existing `editProxyLongEdge` ≈ 1080; do not add a mipmap pyramid).
- Stage-level reuse: extend the existing stage cache (developed film density, linear RGB before scanner — see docs/RENDERING_RESEARCH.md) with a **prefix-hash dirty-tail**: changing a param only invalidates that stage and stages after it. (darktable: `dt_dev_pixelpipe_cache_basichash`.)
- Operators land in three batches (below), each shippable alone, each with UI in the existing ControlsView catalog/slider patterns and QA rebuild discipline from AGENTS.md.

## Non-goals / anti-goals

- No full darktable port (no GTK, no Lua, no OpenCL, no 11-level mipmap pyramid, no preview2, no tethering).
- No continuous/looping auto modes — autos are one-shot histogram/picker setters (darktable pattern), not always-on correctors.
- No changing Spektra's spectral film physics or existing look defaults.
- No new branding, layout language, or third-party UI kits (StudioPalette/StudioLayout/DESIGN.md rules hold).
- Retouch/heal (operator 12) may be deferred indefinitely if quality cannot meet Spektra's bar; do not ship a bad heal brush.
- No dependency additions for these features.

## Constraints

- macOS SwiftUI app, target in Sources/SpektraFilmFast, native C++/Metal in Native/src. Single `AppModel` hub (ObservableObject). Keep that architecture; no @Observable migration in this work.
- Patch pipeline pins in AGENTS.md must stay intact (bundle ids, cache folder names, QA pins, VERSION bump + rebuild + SOURCE_MANIFEST + verify_source after every source edit).
- Intel/Radeon is a real supported machine (RENDERING_RESEARCH.md benchmarks); do not assume Apple Silicon.
- darktable is GPLv3; Spektra is GPLv3 — algorithm ports are license-compatible. Cite darktable file/symbol in code comments when porting math.
- GPU fast path (`GPULiveFramePipeline.supports`) must not be permanently disabled by auto modes; if an auto must run exact, do it once on press, then bake results to concrete params so interaction stays fast.

## How it works (decisions already made)

### Phase 1 — Live edit hardening + Auto UI (this is the approval unit)

**1a. Keep and extend the existing interaction model.** Spektra already mirrors darktable's essential loop:

| darktable | Spektra today |
|---|---|
| idle-coalesced param writes | `beginEditGesture` / `setParam(interactive:)` / `endEditGesture` |
| fixed low-res preview pipe | `editProxyLongEdge` + `InteractivePreviewProxy` |
| latest-request / abort | generation counters (`latestRenderWins`, `gpuPreviewGeneration`) |
| full res on release | settle → exact `scheduleRender` |

Do not replace this with a new pipeline. Work items:

- Ensure every slider (including new autos) goes through `interactive:` gesture protocol.
- While any drag is active, auto-compute steps that today force `supports() == false` are run **once at gesture begin** (or already-computed cached results), not per-tick.
- Coalesce: confirm per-tick work is bounded (one CPU proxy delta per display frame); no new timers needed — generation-drop already prevents pile-up.

**1b. Fix auto fast-path blockers.**

- `autoExposure` currently returns false in `GPULiveFramePipeline.supports` and blocks in `NativeRenderer`. Change: when auto is on, resolve auto to concrete exposure values at the start of a gesture / on auto press (analysis on proxy buffer), then treat the look as those concrete values for fast-path purposes. Keep the auto flag for UI ("Auto" stays checked and can re-run on demand); the render path consumes resolved values.
- Same for `tone.autoContrast` / `filmTone.autoContrast`: resolve once via existing `AutoContrastMath` on the current (proxy) buffer; do not re-evaluate inside the spectral renderer.

**1c. Auto UI (darktable-style one-shot buttons + readouts).** Placement follows DESIGN.md (RAW → Light section, near existing WB/exposure controls):

- **Auto Exposure** button → runs percentile/center-weighted analysis (reuse `StudioImportCalibration` percentile logic + native `autoExposureMethod` choices) on the current develop buffer; applies resulting EV to the darktable-equivalent raw-stage develop exposure (`developExposureEV`); readout shows "Auto +0.42 EV".
- **Auto Contrast** button → wires the existing dead API (`AppModel.setAutoContrast`, `ToneSettings.autoContrast`) with a visible control and readout of computed contrast amount. Must not permanently disable GPU fast path (see 1b).
- **Auto WB** → already exists (picker + "From Auto"); add the button/readout parity if missing in the Light section; keep gray-edge CAT16 path.
- **Auto Baseline** toggle stays (`Toggle("Auto baseline")`); optionally surface its estimated exposureEV/WB as readouts.
- All three apply through normal param setters → undo stack, project save, latest-render-wins. Keyboard/undo behave like any other param change.
- UI copy: photography language ("Auto Exposure", not "deflicker percentile").

**1d. Prefix-hash dirty-tail (stage cache).** Extend the existing stage-reuse cache so each pipeline stage stores `hash = fold(prefixHash, stageParamsHash)`. Editing stage *k* reuses buffers for stages `< k`. Scope: the Swift/CPU host stages + GPU live pipeline stage boundaries that already exist (host grade → film spectral → local grades → lens → geometry). Do not restructure the native spectral renderer internals. If a stage cannot be hashed cheaply (semantic masks mid-drag), treat as non-cacheable (full recompute of downstream) rather than incorrect reuse.

**1e. Histogram source.** Scopes already sample `latestRenderedBuffer` at capped fps. Auto analysis may read the same buffer / decode histogram; do not add a second histogram system. (Optional later: GPU-frame scopes — out of scope for phase 1.)

### Phase 2 — Fast operators (after phase 1 ships)

Batch A (small, catalog-slider pattern, Metal kernel + ControlsView section):

- **Color Equalizer** (hue/sat/light zones) — port algorithm outline from darktable `src/iop/colorequal.c`.
- **Tone Equalizer** — port from `src/iop/tonequal.c`.
- **Color Balance RGB** (lift/gamma/gain + chroma/vibrance) — from `src/iop/colorbalancergb.c`.
- **Graduated ND**, **Vignette/Bloom** polish (LensCharacterEngine extensions) — mostly already partially present; finish and expose.

Each: native param entries via SpektraAppBridge catalog, GPU kernel where interactive, CPU fallback parity check, QA-safe names.

### Phase 3 — Hard operators

Batch B:

- **Filmic RGB / Sigmoid** as alternative tone mappers alongside current host grade (opt-in per look; default unchanged).
- **Diffuse / guided blur** (detail work).
- **Ashift-style keystone** → extend GeometryEngine beyond current keystone if missing corners.
- **Lens correction** via lensfun data or static profiles (license check before bundling).

### Phase 4 — Last / optional

- **Denoise upgrade** (NLM/wavelet-class) — only if it beats current RawForgeDenoise on real photos; otherwise keep RawForge and stop.
- **Parametric masks** (full blend system) — large; MaskMetalEngine exists for semantic masks; full darktable-style drawn+parametric blend is its own project with its own design doc.
- **Retouch/heal** — only with a quality bar; likely last or never.

## Decisions after builder-check (author's calls; human may veto)

1. **Auto lifecycle = darktable one-shot.** The Auto Exposure / Auto Contrast controls are **buttons that apply values**, not live correctors. Pressing Auto analyzes once and writes concrete params. A checked "auto" state, where it exists today, means "last values came from auto" / "re-run on next explicit press or next photo open" — never "re-meter every render." Manually dragging the corresponding slider clears the auto-was-applied state (matches existing `autoContrast` clear-on-manual in AppModel). This supersedes native `autoExposure` re-meter-per-render behavior.
2. **Auto Exposure target = the same stage darktable's exposure module uses.** darktable deflicker/auto writes the early linear `iop/exposure` module (scene-referred EV on raw, after WB, before tone/film). Spektra equivalent: the raw-stage develop exposure (`RawSettings.developExposureEV` / the Light-section exposure bound to that stage) — not `ToneSettings.exposureEV`, `filmExposureEv`, or `hdrExposureEv`. If the UI currently surfaces that raw-stage exposure under a Tone heading, the button still writes the raw-stage param; builder wires to the darktable-equivalent stage, whichever label it sits under.
3. **Legacy projects:** on open/first render, if `autoExposure`/`autoContrast` flags are true and no resolved values are stored, resolve once on the proxy buffer, write resolved values, keep the flags as "came from auto." No permanent slow path for old files.
4. **Analysis buffers:** Auto WB (gray-edge/CAT16) runs on linear RAW **before** user WB. Auto Exposure/Contrast percentiles run on the linear buffer **before** the host tone grade (input to the stage they adjust), matching darktable levels/exposure deflicker. Pressing Auto Exposure then Auto Contrast is ordered: exposure first, then contrast on the post-exposure buffer.
5. **Prefix-hash dirty-tail scope (phase 1) = interactive/proxy path only.** Full-res continues to use the existing bounded film-stage/scanner-stage cache (≤128MB gate). No new full-res intermediates. Full-res dirty-tail is a later optimization if profiling demands it.
6. **Phase-4 denoise bar:** when we get there, side-by-side on the human partner's own photos (noise residual + detail retention + speed); if they prefer RawForge, skip the NLM port.

## What's left to the builder (implementation plan)

- Exact call sites for auto-resolve (which function computes and stores resolved EV/contrast/WB; where `supports()` checks change).
- Hash function design (which bytes: param value canonical form + ROI + source fingerprint).
- Metal kernel structure for each phase-2 operator (reuse existing kernel file patterns).
- Test plan: visual regression fixtures already in repo culture (LUT matrices); add gesture-simulation timing budget on Intel/Radeon (proxy < 33 ms/frame target on the reference machine is a goal, not a guarantee).
- VERSION bump, QA pin verification, SOURCE_MANIFEST per AGENTS.md.

## Risks

- Hash mismatch → stale buffer reuse (wrong image). Mitigate: conservative "uncacheable" default; only cache stages with proven stable param serialization; pixel-identical cache matrices like existing stage-reuse tests.
- Auto resolve on proxy buffer differs from full-res auto (darktable syncs preview→full by hash; we accept small EV/contrast difference between proxy analysis and full render, same as current import calibration).
- Phase 2–4 operator quality (looks "darktable-like" but not photographic) — ship behind defaults-off per look until trusted.
- Scope creep: 12 operators + pipeline + UI is months; phases must ship independently.
