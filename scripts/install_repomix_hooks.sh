#!/usr/bin/env bash
# Install the repomix pre-commit / pre-push hooks. Hooks live in .git/ and are
# therefore not versioned; this script is the source of truth for them.
#   ./scripts/install_repomix_hooks.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$ROOT/.git/hooks"
mkdir -p "$HOOKS"

for hook in pre-commit pre-push; do
  cat >"$HOOKS/$hook" <<'HOOK'
#!/usr/bin/env bash
# Managed by scripts/install_repomix_hooks.sh — regenerate the repo pack so the
# committed repomix-output.xml never drifts from the tree.
set -euo pipefail
REPO="$(git rev-parse --show-toplevel)"
"$REPO/scripts/regen_repomix.sh"
# If the pack changed, stage it and refresh the manifest that CI verifies.
if ! git -C "$REPO" diff --quiet -- repomix-output.xml; then
  git -C "$REPO" add repomix-output.xml
  "$REPO/scripts/refresh_source_manifest.sh" >/dev/null 2>&1 || true
  git -C "$REPO" add SOURCE_MANIFEST.sha256 2>/dev/null || true
  echo "repomix: repacked and staged" >&2
fi
HOOK
  chmod +x "$HOOKS/$hook"
  echo "installed $HOOKS/$hook"
done