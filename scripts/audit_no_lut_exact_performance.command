#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "SpektraFilmFast exact/no-LUT performance audit"
echo "HEAD: $(git rev-parse HEAD)"
echo
echo "[pinned renderer switches]"
grep -E 'SPEKTRAFILM_(FINAL_CORE_MODE|SCANNER_IMAGE_STORAGE|GRAIN_BLUR_RECURRENCE|SPECTRAL_TRANSMITTANCE|DIR_TAIL_BACKEND|BLUR_BACKEND|BLUR_DOWNSAMPLE|INTERMEDIATE_PRECISION|DIFFUSION_CLUSTER_SIGMA|HALATION_GROUPED_TAIL|SCANNER_MPS|DENSITY_CURVE_LOOKUP)' Sources/SpektraFilmFast/NativeRenderer.swift || true
echo
echo "[source upload diagnostics]"
grep -nE 'sourceCopyMs|uploadBytes|sourceNoCopy|destinationNoCopy' Sources/SpektraFilmFast/NativeRenderer.swift Native/src/SpektraAppBridge.h Native/src/SpektraMetalRenderer.mm | head -100
echo
echo "[LUT runtime scan]"
if grep -R -nE 'lutTexture|apply.*LUT|\\.cube' Sources/SpektraFilmFast Native/src --exclude='*.md'; then
  echo "WARNING: inspect matches above."
else
  echo "PASS: no LUT runtime wiring found."
fi
echo
echo "On the Intel Mac, watch sourceCopyMs/sourceNoCopy/uploadBytes."
echo "A full-image upload every frame means the Swift source array is still missing the no-copy path."
