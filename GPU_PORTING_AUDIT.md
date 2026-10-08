# Strict GPU-only request — implementation boundaries

The previous release's *fallback* problem was real: when Lens Character Metal failed it automatically ran a slow CPU optical pass, and Redlamp masking ran CPU coverage on failed Metal evaluation. Both fallback calls are removed by the bundled external-scratch patch.

The former replacement incorrectly allowed a failed GPU stage to **skip that effect** and then write a JPEG. This package adds a generation checkpoint: if masking or lens GPU evaluation reports failure, Edit preview generation throws and a per-file Export task refuses to call the output writer. The alert remains visible. A failure on another concurrent render may also fail the current render, which errs on the side of correctness.

### Still NOT GPU-only (requires new GPU implementations)

- Apple RAW decode and demosaic through macOS ImageIO/Core Image (may involve CPU and GPU internally, not app-controlled GPU-only).
- Host-grade algorithms (`PixelBufferF32.applyingHostGrade`), exposure boundary, and interactive proxy code run Swift/Accelerate CPU operations.
- `GeometryEngine.transformed` and much of resizing are CPU/vImage.
- Some masks are derived by Apple Vision/ONNX and may execute CPU and/or ANE depending on model/backend.
- RGB packaging, metadata and JPEG/HEIC compression may use CPU; they are I/O/encoding, but still not "GPU anywhere".
- The RawForge denoiser invoked `--device cpu`; the patch now **disables it** until a verified Metal backend exists, including disallowing previously CPU-denoised cache results.

A literal **zero-CPU image pipeline requires replacing or disabling these primary algorithms**, not just fallback switches. This patch doesn't falsely claim to accomplish that. The original SpektraFilm spectral/negative/print model is not replaced by LUTs. For production optimization on Intel: profile one exact 80%-JPEG export from the timing CSV and then port the highest-cost CPU processing kernels to Metal in a tested sequence.

### Original-storage boundary

The earlier external-scratch patch ensures only Edit/Export intentionally stage cloud originals and disables neighbor prefetch. However Apple File Provider can still place an iCloud Drive original on the internal disk before an external-scratch copy. This cannot be guaranteed otherwise when the source is iCloud Drive. For **strict external-only downloads**, the R2/remote backend and a streamed-to-external downloader must replace File Provider materialization. These pieces are not fully connected yet.
