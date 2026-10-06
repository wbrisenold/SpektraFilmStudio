# Stage 5 — Production Hardening / Performance

- Lens Character now prefers a tiled 16×16 Metal compute kernel for 1080 px preview and full-resolution export.
- The Stage 4 CPU lens implementation remains as a deterministic fallback only.
- RawForge prewarm supports current Library selection and export-marked photos, bounded to two workers on Intel.
- Batch results report elapsed time and warm-cache hits so running the same set twice provides cold/warm measurements.
- Cache accounting reports RawForge DNG and bundled AI-model sizes independently; semantic masks remain RAM-only and render cache remains separate.
- Lens or denoise changes continue to invalidate Stage 3 canonical semantic masks before the next Skin/AI analysis.
- `scripts/qa_stage5.py` gates the normal Intel build and verifies preview/export lens parity, cache separation, canonical-mask invalidation, bounded prewarm and Intel-only build assumptions.
- Film/spectral math is untouched. Lens Character remains post-film and pre-geometry/crop.

## Production validation still required on macOS
This checkpoint can statically validate source and packaging in a non-macOS environment, but the x86_64 app must still be compiled and the Metal kernel exercised on the target Intel Mac/Xcode runtime.
