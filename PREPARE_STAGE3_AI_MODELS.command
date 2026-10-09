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
python3 scripts/prepare_sam2.py
cat > "$AI_DIR/PROVENANCE.txt" <<'P'
SAM 2.1 Tiny — https://huggingface.co/apple/coreml-sam2.1-tiny — Apache-2.0; pinned manifest: Resources/SAM2TinyManifest.json
ONNX Runtime — https://github.com/microsoft/onnxruntime — MIT
P

echo "Stage 3 AI runtime/models ready."
