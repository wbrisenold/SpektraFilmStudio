#!/usr/bin/env bash
# Regenerate SOURCE_MANIFEST.sha256 in the format verify_source.sh enforces:
# `sha256  path`, LC_ALL=C sorted, relative to the repo root.
#
# The exclusion list below must stay identical to the `find` in
# verify_source.sh; this script ends by running verify_source.sh so a drift
# between the two fails loudly instead of shipping a bad manifest.
#   ./scripts/refresh_source_manifest.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

find . -type f \
  -not -path './.build/*' \
  -not -path './dist/*' \
  -not -path './.git/*' \
  -not -path './Vendor/*' \
  -not -path './.superpowers/*' \
  -not -path './.opencode/*' \
  -not -path './Resources/AIModels/*' \
  -not -name 'SOURCE_MANIFEST.sha256' \
  -not -name '.DS_Store' \
  -not -path './.batch-edit-backup-*' \
  -not -path './.agents/*' \
  -not -path './Skills/*' \
  -print | sed 's#^./##' | LC_ALL=C sort \
  | tr '\n' '\0' \
  | xargs -0 shasum -a 256 >SOURCE_MANIFEST.sha256

echo "SOURCE_MANIFEST.sha256: $(wc -l <SOURCE_MANIFEST.sha256 | tr -d ' ') files"

if ! ./scripts/verify_source.sh >/dev/null 2>&1; then
  echo "refresh_source_manifest: verify_source.sh failed after regeneration" >&2
  exit 1
fi
echo "SOURCE_MANIFEST.sha256: verified"