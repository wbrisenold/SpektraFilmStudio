# Research provenance (verified 2026-10-12)

This is an implementation based on *publicly documented* engineering practices, not a reproduction of OpenAI model internals, private system instructions, or trained weights. Do not claim it changes the underlying AI's intelligence or guarantees ChatGPT-level results.

## OpenCode implementation contracts

- Skills: https://docs.opencode.ai/docs/skills/ — `.opencode/skills/<name>/SKILL.md`, valid YAML frontmatter, on-demand `skill` tool, global/project locations.
- Rules: https://docs.opencode.ai/docs/rules/ — `AGENTS.md` project/global instructions, `/init`, external instructions.
- LSP: https://docs.opencode.ai/docs/lsp/ — SourceKit-LSP as built-in integration for `.swift` with installed Swift/Xcode; LSP disabled by default, not a substitute for compiler.
- Commands: https://docs.opencode.ai/docs/commands/ — markdown commands and `$ARGUMENTS`.
- Config: https://docs.opencode.ai/docs/config/ — `opencode.json`, merging, global/project paths.

## OpenAI and Codex engineering behaviors (public statements)

- https://openai.com/index/harness-engineering/ — short AGENTS.md navigation rather than a giant rule blob, architecture/test invariants enforced via tooling, depth-first design/implementation/review/test, agent-legible repository state.
- https://openai.com/index/introducing-codex/ — output verification via logs/tests, explicit uncertainty, human review.
- https://openai.com/index/introducing-upgrades-to-codex/ — Codex agent training focuses on real-world software engineering, debugging, reviews, tests, and iteration.
- https://openai.com/index/o3-o4-mini-codex-system-card-addendum/ — test/lint/typecheck loops and verifiable evidence; no proprietary reasoning or prompts exposed.

## Swift technical sources

- https://www.swift.org/migration/documentation/migrationguide/ — Swift 6 compiler version versus language mode; actor isolation, gradual concurrency migration.
- https://github.com/swiftlang/sourcekit-lsp — index/navigation/diagnostics, tooling constraints.
- https://developer.apple.com/documentation/xcode — Xcode/toolchain build documentation.
- https://github.com/realm/SwiftLint — linting, optional additional static checks.

## Research-derived design decisions

1. Compact core SKILL.md, references only on demand (progressive disclosure).
2. Mandatory evidence-based implementation loop, with meaningful STOP/NOT RUN statuses.
3. Real tooling and tests preferred to more emphatic prompts.
4. Swift-specific appendix targets deployment compatibility, API hallucination, concurrency, and photo-editor integration.
5. A separate invocable `/engineer` command ensures the skill can be requested explicitly; an optional AGENTS template carries a lighter project-wide policy.
