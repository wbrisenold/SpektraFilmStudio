# Stage 2 — Mask / Layer Core

Implemented foundation:
- serialized LocalGradeRecord on RenderLook;
- ordered MaskStackRecord;
- radial, linear-gradient and editable raster payload sources;
- enabled / invert / opacity / feather;
- Add / Subtract / Intersect stack semantics;
- self-contained RLE raster payload for project persistence;
- runtime-compiled Metal kernels for radial/gradient coverage, stack combine and RGBA32F compositing;
- editor mask panel;
- fitted-image mask overlay preview;
- mask edits use the existing look undo stack and exact-preview refresh path.

AI segmentation is intentionally not part of Stage 2. Stage 3 will feed its canonical segmentation masks into this same raster-mask path.
