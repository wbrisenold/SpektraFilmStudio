#!/usr/bin/env bash
# Regenerate repomix-output.xml for the repo, but only rewrite it when the
# packed content actually changed. Wired into the pre-commit and pre-push git
# hooks by scripts/install_repomix_hooks.sh, and documented in
# AGENTS_BUILD_PROTOCOL.md step 5.
#
# Idempotent on purpose: repomix takes ~40s and rewrites an 8.7 MB file, so an
# unchanged repo must not touch the file or churn SOURCE_MANIFEST.sha256.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="repomix-output.xml"
TMP="$(mktemp -t repomix).xml"
trap 'rm -f "$TMP"' EXIT

if ! command -v npx >/dev/null 2>&1; then
  echo "repomix: npx not found; skipping (node + npx required)" >&2
  exit 0
fi

npx --yes repomix@latest . -o "$TMP" --style xml --quiet >/dev/null 2>&1 || {
  echo "repomix: pack failed; leaving $OUT untouched" >&2
  exit 0
}

if [[ -f "$OUT" ]] && cmp -s "$TMP" "$OUT"; then
  echo "repomix: $OUT already current"
  exit 0
fi

mv "$TMP" "$OUT"
trap - EXIT
echo "repomix: regenerated $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"