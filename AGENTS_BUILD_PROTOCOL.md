# Build Contract: ChatGPT ↔ Opencode (SpektraFilmStudio)

## Shared Language / Canon
- Commit basis: must reference exact `HEAD` (short hash + msg). ChatGPT reads latest pushed commit to infer patch basis.
- HEAD-locked: each patch ZIP names/targets the commit it was authored against (e.g. `87d95c4`). If HEAD moved, patch must be re-audited.
- No version bump unless explicitly stated.
- Intel x86_64 only builds. No `--arch arm64`/fat lipo re-introduced. Vendored native core only (`Native/*`, generated curves committed). No external git fetch in build/bootstrap.
- Backups: patchers create timestamped `.spektrafilm-*-backup-*` dirs; **delete them** after successful apply/verify before commit.
- Manifest: `SOURCE_MANIFEST.sha256` format `sha256  path` (LC_ALL=C, sorted). Regenerated after any source edits; `verify_source.sh` enforces coverage + `shasum -a 256 -c`.

## Workflow
1. ChatGPT produces a patch ZIP (changes + apply.py + tests + QA_GATE.md). Names include date/slug.
2. Opencode (this agent): extract, `apply.py --check` on current HEAD → must be 0. Apply, delete backups, inspect build errors, fix **only patch-introduced** build issues (document pre-existing warnings).
3. Build Intel x86_64 (`./scripts/build_app.sh`), 0 warnings/errors target (ship with pre-existing warnings only if explicitly decided).
4. Gates: `bash scripts/verify_source.sh` and `bash scripts/qa_10_passes.sh` both PASS.
5. Regenerate `SOURCE_MANIFEST.sha256`, commit (concise msg referencing patch), push `main`, force-push tag `v0.6.8` if still patching same release line.
6. Build zip + `dist/SHA256SUMS.txt` updated; upload to release `v0.6.8` with `--clobber` (detached for large files). Poll until digest matches.
7. Update `AI_HANDOFF.md` with commit, build sha, elapsed, gates, warnings (pre-existing vs new).

## Build Error Taxonomy
Record every build error encountered in `AI_HANDOFF.md` under `Build Issues Encountered` with: file:line, error, root cause, fix applied, whether pre-existing. Never fix pre-existing warnings without explicit instruction.

## Communication Contract
- ChatGPT → tells "patch at <path>, target HEAD <hash>" (or reads from push).
- Opencode → returns: applied commit hash, build exit/time/sha256, gates PASS/FAIL, warnings list, upload status.
- Avoid editing unrelated files for warnings. If fix touches API/Sendable outside patch scope, log and defer (user decides).

## Self-Tests
If patch provides `tests/*.py`, run them after apply (before build). Self-tests in app (`SpektraFilmStudio --self-test`, `--mask-overlay-self-test`) run after build if present.

## Release Artifact Policy
Dist zips are gitignored. Regenerate fresh zip per pushed commit (Intel only). `SHA256SUMS.txt` must match zip sha256. Large uploads run detached (`nohup gh release upload ... --clobber &`), poll digest.
