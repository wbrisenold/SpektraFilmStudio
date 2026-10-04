# SpektraFilmFast v0.5.1 — Preview and Cache Performance Audit

The exact settled render remains the source of truth. v0.5.1 uses a persistent linear working-file source plus latest-request-wins scheduling. Pointer movement may use display-only feedback, while mouse-up/commit schedules the accurate configured normal preview.

## Hot-path rules

- Ordinary renderer adjustments reuse compatible decoded/developed sources instead of repeatedly redeveloping RAW.
- RAW Temperature/Tint use a temporary linear Rec.2020 adaptation during active pointer motion; the committed preview returns to exact RAW development.
- One native render may be active and only one newer pending request is retained; obsolete intermediate requests are dropped.
- Large float-buffer packaging stays off the main actor.
- Interactive baseline frames can be downscaled with Accelerate/vImage instead of asking the RAW decoder to produce another source.
- The interaction proxy is never stored as the final adjusted-preview cache entry.
- Working files default to 1080 px long edge (`workingFileLongEdge`) and persist as developed linear sources.
- Live and idle native edit renders are fixed at a 1080 px long edge; older project preview-size values are decoded for compatibility but do not override the active edit policy.
- Exact normal previews use the configured `previewLongEdge` (1800 px default); Full Resolution Preview and export are explicit full-source paths.

## Persistent cache layers

The cache root contains independently schema-versioned stores for:

1. thumbnails;
2. developed linear preview sources;
3. exact adjusted previews;
4. Smart Cull analysis.

One total disk budget is divided across those stores, and RAM caches are byte-budgeted separately. Warning memory pressure trims volatile caches; critical pressure drops volatile preview state and cancels compatible work without touching originals/projects.

A user-selected cache parent may be on a writable internal volume or mounted external drive. An unavailable custom drive is reported as unavailable instead of silently changing the selected location.

## Correctness boundary

The live proxy is a responsiveness aid only. It does not redefine the image-processing result. The exact renderer, pinned native bridge/resources, configured normal-preview size, Full Resolution Preview, and full-resolution export remain the correctness paths.

## Architectural ceiling

The Spektrafilm spectral simulation is heavier than a single-pass editor shader. Further large gains that preserve identical settled output would require deeper native intermediate caching or direct Metal-buffer viewer integration. v0.5.1 therefore concentrates on avoiding duplicate decode/prep, stale request backlog, unnecessary cache misses, and incorrect persistence of transient interaction frames.
