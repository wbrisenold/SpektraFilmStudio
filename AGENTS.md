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
