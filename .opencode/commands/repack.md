---
description: Repack repomix-output.xml and refresh SOURCE_MANIFEST.sha256 before committing or pushing
agent: build
---

Run `./scripts/regen_repomix.sh` then `./scripts/refresh_source_manifest.sh` from the repo root, stage `repomix-output.xml` and `SOURCE_MANIFEST.sha256`, and report the file/token counts. Both scripts are idempotent: an unchanged tree is a no-op. If the `pre-commit`/`pre-push` hooks are already installed (`ls .git/hooks/pre-commit`), the same work happens automatically — do not duplicate it. Task: $ARGUMENTS