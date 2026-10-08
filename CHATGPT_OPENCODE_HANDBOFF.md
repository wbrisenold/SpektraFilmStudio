# ChatGPT ↔ Opencode Handoff

## Contract
- Basis: ChatGPT reads latest pushed `HEAD` on `main` to author patch against exact commit.
- HEAD-locked: each patch ZIP must target the commit it was generated for (stated in README). `apply.py --check` must PASS against current checkout; if uncommitted changes exist, stash or provide clean checkout.
- Apply order: extract, run `apply.py --check` (must exit 0), apply, delete any `.*backup*` dirs created, build Intel x86_64, run gates, regenerate manifest, commit+push.
- Build: Intel x86_64 only (`swift build -c release --arch x86_64`). No arm64/fat lipo. Vendored native core only; no external git fetches.
- Warnings: do not fix pre-existing warnings (tracked in AI_HANDOFF.md). Only fix patch-introduced build errors. 0 new warnings/errors.
- Gates: `scripts/verify_source.sh` PASS and `scripts/qa_10_passes.sh` PASS before commit.
- Manifest: `SOURCE_MANIFEST.sha256` regenerated after edits (format: `sha256<sp>path`, LC_ALL=C sorted). Must cover all tracked sources (exclusions match verify_source.sh).

## Patch submission
- ZIP name: include date+slug. Contains `apply.py`, `overrides/`, `tests/`, `QA_GATE.md`, `README.md`, `INSTALL_ON_MAC.command` (if present).
- ChatGPT must say: "target HEAD: <short hash>" when submitting patch (or include in README). Opencode will verify against current HEAD and abort if mismatch without re-audit.

## Return values (Opencode)
Return: applied_commit, gates (verify/qa), build_elapsed_sec, dist_zip_sha256, warnings (pre_existing/new), upload_status (PID/state). Update `AI_HANDOFF.md` with concise entry per patch.

## Release artifacts
Dist zips are gitignored. Regenerate per commit. Large uploads detached with `gh release upload --clobber`; poll digest before considering done.
