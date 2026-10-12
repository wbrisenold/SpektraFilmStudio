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
- **Pixelpipe.swift**: Has extraneous `}` error (line 318) and protocol associated types errors
- **Protocol PixelpipeModule**: Requires `InputBuffer` and `OutputBuffer` associated types
- **AnyPixelpipeModule**: Cannot assign to immutable `isEnabled` expression
- **RawMosaicF32/PixelBufferF32**: Type mismatch in `canProcess` calls
