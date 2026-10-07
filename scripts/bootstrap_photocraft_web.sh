#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHOTOCRAFT="$ROOT/Vendor/photocraft"
OUT="$ROOT/.build/photocraft-web"
STAMP="$OUT/.upstream-commit"

if [[ ! -d "$PHOTOCRAFT/.git" ]]; then
  echo "PhotoCraft checkout is missing. Run scripts/bootstrap_unified_rust_core.sh first." >&2
  exit 41
fi

PIN="$(git -C "$PHOTOCRAFT" rev-parse HEAD)"

if [[ "${SPEKTRAFILM_REBUILD_PHOTOCRAFT:-0}" != "1" &&
      -f "$OUT/index.html" &&
      -f "$STAMP" &&
      "$(cat "$STAMP")" == "$PIN" ]]; then
  echo "PhotoCraft web bundle is already current: $PIN"
  exit 0
fi

for tool in cargo rustc rustup; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "PhotoCraft web build requires '$tool'." >&2
    exit 42
  fi
done

rustup target add wasm32-unknown-unknown >/dev/null

if ! command -v trunk >/dev/null 2>&1; then
  echo "Installing Trunk for the pinned PhotoCraft web build..."
  cargo install trunk --locked
fi

rm -rf "$PHOTOCRAFT/dist/web"
(
  cd "$PHOTOCRAFT/apps/photocraft-web"
  trunk build --release
)

SOURCE="$PHOTOCRAFT/dist/web"
[[ -f "$SOURCE/index.html" ]] || {
  echo "PhotoCraft web build did not produce $SOURCE/index.html" >&2
  exit 43
}

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SOURCE"/. "$OUT"/
printf '%s\n' "$PIN" > "$STAMP"

echo "PhotoCraft web bundle ready:"
echo "$OUT"
