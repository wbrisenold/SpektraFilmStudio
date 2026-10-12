# Investigation-to-verification playbook

Read only when a task has nontrivial integration, regression risk, or unclear behavior.

## 1. Establish an evidence baseline

- Discover root: `pwd`, `git rev-parse --show-toplevel`, `git status --short`, `git log -1 --oneline` (if Git).
- Read project `AGENTS.md` and relevant architecture/build instructions. Inspect manifests, CI, pinned dependencies, and current implementation.
- Discover likely references with file/symbol search (`rg` if installed; otherwise `grep`). Inspect callers AND callees; never infer execution from a filename.
- Identify existing tests and record what currently passes/fails; avoid attributing pre-existing failures to the patch.
- List the concrete user-visible states that must change; keep old behavior unchanged unless requested.

## 2. Turn a vague request into an executable contract

Construct a small internal checklist:

| Area | Question |
|---|---|
| Scope | What exact feature or bug is requested? |
| User path | How does the user trigger it and observe success? |
| Preconditions | Required files, permissions, data, hardware, OS, cloud service? |
| Integration | Which UI bindings, domain types, persistence, engines, tests, exports are affected? |
| Invariants | Which behavior, performance, compatibility, data format, and API must not change? |
| Verification | Which automated and runtime checks distinguish working from 'compiles'? |

For new features, prefer one vertical end-to-end implementation over multiple shallow placeholders. For a bug, write or reproduce a failing check before editing when feasible. If reproduction requires devices/services unavailable here, create an isolated test of the closest deterministic behavior and report the remaining uncertainty.

## 3. Make changes with a controlled blast radius

- Prefer minimal, coherent patches and the project's established conventions.
- Avoid dependency additions, new abstraction layers, or reformatting unrelated files without a clear payoff.
- Treat compatibility as a constraint to check rather than a setting to loosen.
- When algorithms or color transformations matter, distinguish mathematically equivalent behavior from a visual approximation; verify with reference vectors and tolerances.
- Document a migration and backout path for schema or serialization changes.
- Check no stubs/unused duplicated paths remain after the change.

## 4. Verification ladder

1. Static correctness: diff, formatting, compiler/type checker, lint, warnings, API existence.
2. Targeted tests: unit tests for the changed behavior and known edge cases.
3. Integration tests: cross-module/state/persistence/renderer/export path with realistic inputs.
4. Application behavior: launch or UI automation/manual walkthrough where runtime is available.
5. Regression/performance: representative old workflows, timing/memory on comparable inputs.
6. Deployment: actual target platform/architecture, SDK availability and build artifact inspection.

Do not conflate these tiers. State exactly which tier was reached.

## 5. Evidence-driven bug debugging

- Extract the FIRST actionable compiler error with file:line and type context. Reproduce with the exact command.
- Diagnose why the type or behavior is incorrect. Inspect signatures and declarations; do not blindly cast or suppress.
- Apply smallest root-cause fix. Run same command again.
- If a second error appears, distinguish newly exposed issues from new regressions.
- Confirm behavior and tests, then compare `git diff --check` and `git diff`.

## 6. Review rubric

Check acceptance criteria, unused/stale references, error handling, resource lifetime, race safety, observability, determinism, regression safety, accessibility, and the difference between intended and actual behavior.

When reviewing without implementing: deliver findings ordered by severity with file/line and reproduction. Do not rewrite code silently.

## 7. Accuracy labels

- `PASS`: command ran and succeeded / behavior observed.
- `FAIL`: command ran and failed (include exact cause).
- `NOT RUN`: not executed, with reason.
- `UNKNOWN`: evidence is inadequate.

Avoid 'should work', 'fixed', 'complete', '1:1', 'GPU-only', 'no CPU fallback', or 'production ready' unless the claim is scoped to evidence.
