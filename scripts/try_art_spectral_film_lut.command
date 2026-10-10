#!/bin/bash
set -euo pipefail
# Real ART integration for Jan Lohse's *different* MIT-licensed Spectral Film LUT model.
# Not a disguised SpektraFilm film profile; outputs remain ACES CLF with their own metadata.
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${ART_LUT_OUT:-$HOME/Downloads/SpektraFilmStudio-ART-SpectralFilmLUT-Trial}"
ART_SHA='25463459ecac44696983242b783865829c505d83'
SFL_SHA='b8d69398fc71038579c20473378be22103695dd5'
mkdir -p "$OUT"
command -v git >/dev/null && command -v python3 >/dev/null || { echo 'Requires Git and Python 3.11+' >&2; exit 2; }
PYTHON="${PYTHON_311:-python3}"
"$PYTHON" - <<'PY'
import sys
if sys.version_info < (3,11):
    raise SystemExit('Python 3.11+ is required by Spectral Film LUT. Set PYTHON_311=/path/to/python3.11')
PY
if [[ ! -d "$OUT/ART/.git" ]]; then
 git clone --filter=blob:none https://github.com/artraweditor/ART.git "$OUT/ART"
fi
if [[ ! -d "$OUT/spectral_film_lut/.git" ]]; then
 git clone --filter=blob:none https://github.com/JanLohse/spectral_film_lut.git "$OUT/spectral_film_lut"
fi
for item in "ART:$ART_SHA" "spectral_film_lut:$SFL_SHA"; do
 name="${item%%:*}"; sha="${item#*:}"
 git -C "$OUT/$name" fetch -q origin "$sha"
 # Safe by construction: the kit only changes generated OUTPUT; refuse to wipe local edits.
 if [[ -n "$(git -C "$OUT/$name" status --porcelain)" ]]; then
  echo "Existing $name checkout has modifications; refusing to overwrite." >&2; exit 4
 fi
 git -C "$OUT/$name" checkout --detach "$sha" -q
done
if [[ ! -d "$OUT/.venv" ]]; then "$PYTHON" -m venv "$OUT/.venv"; fi
PY="$OUT/.venv/bin/python"
# Uses the ACTUAL ART generator, not a hand-drawn substitute.
if ! "$PY" -c 'import spectral_film_lut' 2>/dev/null; then
 echo 'Installing the free MIT-licensed Spectral Film LUT Python dependencies in an isolated venv...'
 "$PY" -m pip install -e "$OUT/spectral_film_lut"
fi
GEN="$OUT/ART/tools/extlut/spectral_film_mklut.py"
[[ -f "$GEN" ]] || { echo "ART generator missing at $GEN" >&2; exit 5; }
FILM="${ART_LUT_FILM:-Kodak Portra 400}"
PAPER="${ART_LUT_PAPER:-Kodak Vision 2383}"
CLF="$OUT/ART-SpectralFilmLUT-ACES-33.clf"
echo "Baking the REAL ART Spectral Film LUT: $FILM / $PAPER"
START="$(date +%s)"
"$PY" "$GEN" --film "$FILM" --paper "$PAPER" --exposure 0 --wb 6500 "$CLF"
SECONDS_TO_BAKE=$(( $(date +%s) - START ))
"$PY" "$HERE/inspect_clf.py" "$CLF" --seconds "$SECONDS_TO_BAKE" --source "$SFL_SHA" --art "$ART_SHA"
echo "ART Spectral Film LUT: $CLF"
echo 'This measures generation time and validates the CLF. It does NOT benchmark GPU preview or imply parity with SpektraFilm.'
