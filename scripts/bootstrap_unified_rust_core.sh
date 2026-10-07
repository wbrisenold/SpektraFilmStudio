#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LC_PIN="b35487add2e8169c18e36dff3a9815501c901d69"
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
  if [[ -d "$dir/.git" ]]; then
    local current
    current="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$current" == "$pin" ]]; then
      echo "Using cached pinned LightCraft checkout: $pin"
      return
    fi
    if git -C "$dir" cat-file -e "$pin^{commit}" 2>/dev/null; then
      git -C "$dir" checkout --detach "$pin"
      return
    fi
  else
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    git clone --filter=blob:none "$repo" "$dir"
  fi
  git -C "$dir" fetch --depth 1 origin "$pin"
  git -C "$dir" checkout --detach "$pin"
}

clone_pin "https://github.com/storytold/lightcraft.git" "$LC_PIN" "$ROOT/Vendor/lightcraft"

mkdir -p "$ROOT/THIRD_PARTY/LightCraft"

for f in LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md; do
  [[ -f "$ROOT/Vendor/lightcraft/$f" ]] && cp "$ROOT/Vendor/lightcraft/$f" "$ROOT/THIRD_PARTY/LightCraft/"
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
