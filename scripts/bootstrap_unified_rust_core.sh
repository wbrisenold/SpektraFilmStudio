#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LC_PIN="b35487add2e8169c18e36dff3a9815501c901d69"
PC_PIN="47f9306fd06d5dee11acb84b108606f4c867222a"
TARGET_DIR="$ROOT/.build/spektrastudio-core"

for tool in git cargo rustc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Unified Rust core requires '$tool'." >&2
    echo "Install Rust with rustup, then rerun." >&2
    exit 31
  fi
done

clone_pin () {
  local repo="$1"
  local pin="$2"
  local dir="$3"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    git clone --filter=blob:none "$repo" "$dir"
  fi
  git -C "$dir" fetch --depth 1 origin "$pin"
  git -C "$dir" checkout --detach "$pin"
}

clone_pin "https://github.com/storytold/lightcraft.git" "$LC_PIN" "$ROOT/Vendor/lightcraft"
clone_pin "https://github.com/storytold/photocraft.git" "$PC_PIN" "$ROOT/Vendor/photocraft"

mkdir -p "$ROOT/THIRD_PARTY/LightCraft" "$ROOT/THIRD_PARTY/PhotoCraft"

for f in LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md; do
  [[ -f "$ROOT/Vendor/lightcraft/$f" ]] && cp "$ROOT/Vendor/lightcraft/$f" "$ROOT/THIRD_PARTY/LightCraft/"
  [[ -f "$ROOT/Vendor/photocraft/$f" ]] && cp "$ROOT/Vendor/photocraft/$f" "$ROOT/THIRD_PARTY/PhotoCraft/"
done

if command -v rustup >/dev/null 2>&1; then
  rustup target add x86_64-apple-darwin >/dev/null
fi

cargo build \
  --manifest-path "$ROOT/Rust/SpektraStudioCore/Cargo.toml" \
  --release \
  --target x86_64-apple-darwin \
  --target-dir "$TARGET_DIR"

LIB="$TARGET_DIR/x86_64-apple-darwin/release/libspektrastudio_core.a"
[[ -f "$LIB" ]] || { echo "Unified static library missing: $LIB" >&2; exit 32; }

echo "Unified SpektraStudioCore ready:"
echo "$LIB"
