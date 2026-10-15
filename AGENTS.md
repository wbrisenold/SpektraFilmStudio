# Global Agent Rules for SpektraFilmStudio

## Hard Rule: Skill Usage Required

**MANDATORY: Before any thinking, analysis, or action, you MUST invoke a relevant skill using the `skill` tool. You MUST output which skill you are using before proceeding with any work.**

### Rule Enforcement:
1. **Before ANY response** - including clarifying questions, code exploration, or file reads - check available skills and invoke the most relevant one
2. **Output format**: "Using [skill-name] to [purpose]" must appear in your response BEFORE any other content
3. **No exceptions** - This applies to ALL tasks: debugging, code review, feature implementation, research, questions, etc.
4. **Skill selection**: Use the most specific skill available. If multiple apply, use the most relevant primary skill first
4. **Verification**: If you respond without invoking a skill first, the response is invalid and must be retracted

### Current Active Skills for SpektraFilmStudio:
- `context-engineering` - Context management, degradation patterns, optimization
- `deep-research` - Autonomous multi-step research (requires GEMINI_API_KEY)
- `debug-with-ai` - AI-assisted debugging
- `systematic-debugging` - Systematic debugging techniques
- `codebase-memory` - Code knowledge graph queries
- `refactor-with-ai` - AI-assisted refactoring
- `code-reviewer` - Automated code review
- `ponytail` - Minimal/simplest solution approach (full level)

### Rule Violation Consequences:
- Any response without skill invocation = INVALID
- Must retract and re-invoke skill before proceeding
- This rule is non-negotiable and cannot be overridden

---

### Currently Active Skills:
1. **context-engineering** - For managing context in the large Pixelpipe.swift refactor
2. **systematic-debugging** - For the build errors in Pixelpipe.swift
3. **codebase-memory** - For navigating the SpektraFilmStudio codebase
4. **ponytail (full)** - Minimal/simplest solution approach

---

**Using context-engineering to manage the complex Pixelpipe.swift refactor context**
**Using systematic-debugging to systematically fix the build errors**
**Using codebase-memory to navigate the SpektraFilmStudio codebase**
**Using ponytail (full) to apply minimal fixes**

---

## Project-Specific Rules (from AGENTS_BUILD_PROTOCOL.md)

See [AGENTS_BUILD_PROTOCOL.md](AGENTS_BUILD_PROTOCOL.md) for build workflow, error taxonomy, and communication contract.

### Build Target
- Intel x86_64 only (`./scripts/build_app.sh`)
- Zero warnings/errors target
- Gates: `verify_source.sh` and `qa_10_passes.sh` must PASS

### Current Build Status
- **Build**: Clean Intel x86_64 release build (commit 7bab178). Zero Swift compile errors.
- **Gates**: `verify_source.sh` PASS, `qa_10_passes.sh` 10/10 PASS.
- **Tone pipeline**: Fully removed. The live-GPU sigmoid/AgX/FilmicRGB tone engine (Ported Lightamer pipeline: `PipeSettings`, `PipeStage`, `ToneEngineSelection`, `NLMeans/Bilateral/Lens/Sigmoid/AgX/FilmicRGB` params + modules) was deleted from the repo. The live preview path is now pure spectral film + native Metal host grade.
- **LUT modes**: User-facing LUT/Looks GPU preview and import modes removed (no `--lut-smoke-test`; replaced by `--render-integrity-test`). Native spectral film is the only film stage. `StudioSpectralLUT.swift` deleted; `NativeRenderer.colorLUTBlockingReason`/`isColorLUTEligible` are no-ops.
- **Remaining tone systems**: The core host grade `ToneSettings` (curves, film exposure shape) is untouched — it is the photo's tone, not the live pipe. `ToneGradeEngine.swift` provides the host grade.

Updated AGENTS.md to reflect the removal. The P0 items listed above (P0-A/P0-D/P0-E/P1-C/P1-A) are all resolved since the pipe was removed.


## QA Philosophy (as of 2026-10-15)

**The gate must verify behavior, not prescribe architecture.** String-matching gates
(`require("token" in file)`) repeatedly blocked legitimate refactors by enforcing
calls the current code deliberately does not make. The gate is now:

1. **Type-check** (`swiftc -typecheck`) — catches real compile errors.
2. **Static invariants** — only rules that must always hold (security, offline-build,
   resource integrity, banned APIs like `NSImage(contentsOf:)` outside thumbnails).
3. **Behavioral QA** (`scripts/qa_10_passes.sh` pass 11) — builds the app, launches it
   via the CUA driver, navigates to the Edit page, and asserts no crash. This is the
   gate that catches what string checks cannot.

The CUA-driven workflow (`scripts/cua_edit_page_test.sh`) is the source of truth for
"does the app actually work." If a code change breaks the app, the CUA test fails —
not a stale string assertion. Screenshots from the run are passed back to the model
for visual verification.

Run it manually: `./scripts/cua_edit_page_test.sh`

## Live Preview / GPU Slider Gate

The interactive edit path for sliders is only GPU-live when all of these hold:
- `project.preferences.bypassImportTransform` is false (this is checked first and falls back to the exact renderer otherwise)
- `currentSourceSupportsGPULive` is true for the selected source
- `GPULiveFramePipeline.supports(previewLook)` returns true

`supports()` currently rejects:
- enabled local grades/masks
- unresolved `tone.autoContrast` or `filmTone.autoContrast`
- `look.raw.denoiseMode != .off`
- non-primary skin tone paths

If a slider still triggers a load, the fallback `scheduleRender` path is being taken.
Check the on-screen renderer path label (`rendererPathStatus`) while dragging:
- `Metal ...` means GPU live is active
- any "Metal unavailable" / exact path means one of the gates above is preventing GPU live.

The live loop also coalesces pointer updates with a 16 ms `Task.sleep` before
decoding/rendering, so identical slider movement should reuse the cached RAW prefix
instead of repeating the authoritative native render.

## High-Finding Resolution (2026-10-15)
- GPU live slider failures now set `rendererPathStatus` to `Exact fallback: <reason>`.
- Rejection reasons mirror `GPULiveFramePipeline.supports`: unsupported source, bypassed import transform, local masks, unresolved auto contrast, RAW denoise, and non-primary skin path.
- Completed the removed GPU pipe-pipeline deletion in AppModel and ControlsView; no source references to `Pipe*` remain.
