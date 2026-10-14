#!/usr/bin/env bash
# Fetch open-licence RAW fixtures (exiftool test corpus) for decode coverage.
# Fixtures are NOT committed; this script is the source of truth.
#   ./tests/fixtures/fetch_raw_fixtures.sh
set -euo pipefail

DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/raw"
BASE="https://raw.githubusercontent.com/exiftool/exiftool/master/t/images"

# Vendor format coverage: Canon CR2/CR3/CRW, Fuji RAF, DNG, Panasonic RW2,
# Nikon NEF, Sigma X3F, PhaseOne IIQ, Red R3D, Kyocera RAW.
FILES=(
  CanonRaw.cr3 FujiFilm.raf DNG.dng Panasonic.rw2 CanonRaw.cr2
  CanonRaw.crw Nikon.nef SigmaDP2.x3f PhaseOne.iiq Sigma.x3f
  Red.r3d KyoceraRaw.raw
)

mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  if [[ -s "$DEST/$f" ]]; then
    echo "skip   $f (present)"
    continue
  fi
  curl -fsSL --max-time 60 -o "$DEST/$f" "$BASE/$f"
  echo "fetch  $f ($(wc -c <"$DEST/$f" | tr -d ' ') bytes)"
done

echo "raw fixtures: $(find "$DEST" -type f | wc -l | tr -d ' ') files in $DEST"