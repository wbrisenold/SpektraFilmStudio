#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# ponytail: 1.30.0 ships ARM-only; this project is x86_64-only, so pin the
# newest ORT release that still publishes a macOS Intel artifact (1.22.0).
ORT_VER="1.22.0"
AI_DIR="Resources/AIModels"
VENDOR="Vendor/onnxruntime"
mkdir -p "$AI_DIR" "$VENDOR"
ARCHIVE="/tmp/onnxruntime-osx-x86_64-${ORT_VER}.tgz"
if [[ ! -f "$VENDOR/include/onnxruntime_cxx_api.h" ]]; then
  echo "Downloading ONNX Runtime ${ORT_VER} x86_64…"
  curl -L --fail -o "$ARCHIVE" "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VER}/onnxruntime-osx-x86_64-${ORT_VER}.tgz"
  TMP=$(mktemp -d); tar -xzf "$ARCHIVE" -C "$TMP"; SRC=$(find "$TMP" -maxdepth 1 -type d -name 'onnxruntime-*' | head -1)
  cp -R "$SRC/include" "$VENDOR/"; cp -R "$SRC/lib" "$VENDOR/"; rm -rf "$TMP"
fi
fetch(){ local url="$1" out="$2"; [[ -f "$out" ]] || { echo "Downloading $(basename "$out")…"; curl -L --fail "$url" -o "$out"; }; }
fetch "https://huggingface.co/gradio/Modnet/resolve/2e7196ed50d5d60f99a73f737421d9760cf05e0c/modnet.onnx" "$AI_DIR/modnet_photographic.onnx"
MODNET_SHA="07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9"
ACTUAL_MODNET_SHA=$(shasum -a 256 "$AI_DIR/modnet_photographic.onnx" | awk '{print $1}')
[[ "$ACTUAL_MODNET_SHA" == "$MODNET_SHA" ]] || { echo "MODNet checksum mismatch" >&2; exit 21; }
fetch "https://huggingface.co/pirocheto/schp-lip-20/resolve/main/onnx/schp-lip-20-int8-static.onnx" "$AI_DIR/schp-lip-20-int8-dynamic.onnx"
fetch "https://huggingface.co/PayamFard123/dermaintel-face-parsing/resolve/main/resnet18.onnx" "$AI_DIR/face_parsing_resnet18.onnx"
cat > "$AI_DIR/PROVENANCE.txt" <<'P'
MODNet — https://github.com/ZHKKKe/MODNet — Apache-2.0
SCHP LIP-20 ONNX — https://huggingface.co/pirocheto/schp-lip-20 — MIT model repository
Face parsing BiSeNet — https://github.com/yakhyo/face-parsing / https://huggingface.co/PayamFard123/dermaintel-face-parsing — MIT
ONNX Runtime — https://github.com/microsoft/onnxruntime — MIT
P

echo "Stage 3 AI runtime/models ready."
