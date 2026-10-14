#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo '1/4 Source and color-contract regression tests'
python3 scripts/qa_production.py
python3 scripts/qa_export_dialog.py
bash scripts/verify_source.sh

echo '2/4 Verify compiled Intel application is present'
APP="$ROOT/dist/SpektraFilmStudio.app/Contents/MacOS/SpektraFilmStudio"
if [[ ! -x "$APP" ]]; then
    echo "No built Intel app at: $APP" >&2
    echo 'Build first: bash scripts/build_app.sh' >&2
    exit 7
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Metal smoke requires macOS.' >&2; exit 8
fi
ARCHS="$(lipo -archs "$APP")"
[[ "$ARCHS" == *x86_64* ]] || { echo "Wrong app architecture: $ARCHS" >&2; exit 9; }

echo '3/4 Execute native spectral render integrity smoke in built app'
"$APP" --render-integrity-test 2>&1 | tee "$TMP/metal-smoke.log"
grep -q 'RENDER_INTEGRITY_PASS' "$TMP/metal-smoke.log" || { echo 'App did not report a render integrity pass' >&2; exit 10; }
echo 'PASS: native spectral film, no LUT modes, tone engine selection verified.'
