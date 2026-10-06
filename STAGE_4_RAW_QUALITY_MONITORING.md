# Stage 4 — RAW Quality + Monitoring

- RawForge 0.2.4 RAW/CFA denoise cache (MIT), with Auto ISO-derived or Manual luma/chroma strengths.
- Denoise output is a cached DNG consumed by the normal decoder; no post-render blur substitution.
- Saturation scope and image-space false-color exposure monitor remain off the render-critical path and analyze the published 1080 px frame.
- Render, semantic-mask, and RawForge DNG caches are isolated and separately clearable/validatable.
- Lens Character section: 35mm Spherical, 50mm, 85mm, 28mm, Anamorphic 2x, Petzval, Vintage 58mm plus Custom controls for distortion, CA, highlight CA, spherical aberration, Petzval swirl, edge softness, vignette.
- Exact film core is untouched; lens character runs after film color and before crop/geometry.
- Stage 3 canonical Skin Only contract remains unchanged.
