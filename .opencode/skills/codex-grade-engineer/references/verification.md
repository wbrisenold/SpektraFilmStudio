# Verification matrix and release gate

A change is deliverable only to the level the checks support.

| Claim | Minimum evidence | What it does NOT prove |
|---|---|---|
| Syntax/type correctness | Successful compiler build for affected target | Runtime behavior |
| Bug fixed | Reproduction was failing; after patch it passes, plus relevant regressions | Every environment |
| SwiftUI behavior fixed | Interaction/state test or actual UI walkthrough | Cross-OS compatibility |
| RAW/color output correct | Known-value pixel fixtures and deterministic image comparison | Subjective film accuracy |
| Preview/export match | Same image + params tested across both paths with tolerances | Every export codec |
| Performance improved | Before/after on same hardware, input and release configuration | Every machine |
| Old Intel macOS supported | Deployment-target/API audit **and** successful test on target macOS/hardware | Other macOS versions |
| Zero fallback for a scope | Explicit call graph and runtime instrumentation of that scope | Zero CPU involvement overall |
| Release ready | Required CI green, artifact exists, smoke tests and blockers disclosed | Perfect, bug-free software |

## Required CI/runtime report

For each criterion, record status, exact executed command, observed result and environment. Warnings/new diagnostics should be inspected rather than erased. Track baseline failures separately.

Example:

```text
Build: PASS  swift build (Swift 6.x, macOS runner)
Tests: FAIL  swift test -> testCacheInvalidation failed
Lint: NOT RUN  swiftlint not installed
Oldest macOS: NOT RUN  no Catalina test host available
Feature: UNKNOWN  no screenshot/UI automation executed
```

## Git safety

Before editing: `git status --short` and base SHA. After: `git diff --check`, review diff, search for call sites and removed symbols. Never use `git reset --hard`, `git clean -fd`, forced checkout, destructive branch operations, or force push to make a patch apply. When the working tree differs from an expected patch base, rebase the *patch logic* on the present code, not overwrite the present code.

## Complete-change acceptance check

- Was every stated criterion addressed, or marked incomplete?
- Does the edited path execute in the current app?
- Are inputs/outputs, state, persistence, error handling and export all wired?
- Are old behaviors intact, including keyboard/accessibility and cancellation?
- Did tests fail before and pass after where reproducible?
- Did warnings, race hazards, and platform APIs get checked?
- Are logs, artifact paths, and build claims factual?

If not, state the limitation explicitly rather than manufacturing certainty.
