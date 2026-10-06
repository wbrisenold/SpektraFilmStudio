#!/bin/bash
set -euo pipefail
PY="${PYTHON3:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then echo "Python 3.11+ is required." >&2; exit 2; fi
"$PY" - <<'PY'
import sys
if sys.version_info < (3,11): raise SystemExit('Python 3.11+ is required for RawForge 0.2.4')
PY
ROOT="$HOME/.local/share/SpektraFilmFast/rawforge-venv"
"$PY" -m venv "$ROOT"
"$ROOT/bin/python" -m pip install --upgrade pip
"$ROOT/bin/python" -m pip install 'rawforge[cpu]==0.2.4'
"$ROOT/bin/rawforge" --help >/dev/null
cat > "$ROOT/SPEKTRAFILM_RAWFORGE_PROVENANCE.txt" <<'EOF'
RawForge 0.2.4 — MIT
https://github.com/rymuelle/RawForge
https://pypi.org/project/rawforge/0.2.4/
Installed as an optional external RAW/CFA denoise provider for SpektraFilmFast Stage 4.
EOF
echo "RawForge ready: $ROOT/bin/rawforge"
