#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo '1/4 Source and color-contract regression tests'
python3 scripts/qa_production.py
python3 scripts/qa_export_dialog.py
bash scripts/verify_source.sh

echo '2/4 Compile/run actual Swift LUT Catalog CSV parser'
command -v swiftc >/dev/null 2>&1 || { echo 'Missing swiftc' >&2; exit 5; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spektra-lut-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# The integration package installs this fixture under scripts/lut_smoke_fixture.swift.
swiftc Sources/SpektraFilmFast/StudioLUTCatalog.swift scripts/lut_smoke_fixture.swift -o "$TMP/catalog-smoke"
"$TMP/catalog-smoke" | tee "$TMP/catalog-smoke.log"
grep -q 'CATALOG_SMOKE_PASS' "$TMP/catalog-smoke.log" || { echo 'Catalog smoke failed' >&2; exit 6; }

echo '3/4 Verify compiled Intel application is present'
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

echo '4/4 Execute actual Metal LUT pixel/cache smoke in built app'
"$APP" --lut-smoke-test 2>&1 | tee "$TMP/metal-smoke.log"
grep -q 'LUT_SMOKE_PASS' "$TMP/metal-smoke.log" || { echo 'App did not report a Metal smoke pass' >&2; exit 10; }
echo 'PASS: LUT smart catalog, GPU upload/reuse, Rec.2020 shaper, bad-file fail-closed.'
