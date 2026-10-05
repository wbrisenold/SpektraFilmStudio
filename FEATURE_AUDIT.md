# Feature audit — SpektraFilmFast 0.5.2

The supplied SpektraFilm standalone and pinned public native bridge remain the renderer parity references. v0.5.2 preserves the host-side Library/Cull/cache/studio workflow without replacing the film engine.

| Capability | v0.5.2 implementation |
|---|---|
| Project / Standalone Photo Mode | `AppModel` lifecycle |
| `.spektrafilm` projects | current format with migration/default decoding |
| Autosave / crash recovery | recovery snapshot + atomic named-project autosave + recovery prompt |
| Dirty-project protection | quit/new/open/destructive transition confirmation |
| Missing-media relink | recursive relink with filename + recorded size/mtime disambiguation |
| `.sfpreset` presets | local library + import/export/apply/delete |
| RAW / still decode | `ImageDecoder` with `CIRAWFilter` / `CIImage` |
| RAW WB / temp / tint / lens correction | RAW controls |
| Auto White Balance | neutral-candidate estimator + weighted gray-world fallback + recalculate action |
| Linear Rec.2020 import path | float Core Image decode; native input forced to Linear Rec.2020 |
| Native Film/Print/DIR/Grain/Halation/Diffusion/Scanner | `SpektraAppBridge` descriptors |
| Library import | immediate records + asynchronous metadata/thumbnail warmup |
| Library organization | search, sort, folders, albums, smart collections |
| Library decisions | ratings, pick/reject, color labels, batch actions, export inclusion |
| XMP | read/write sidecars + optional automatic rating/flag/color writes |
| Persistent thumbnails | small + medium persistent cache |
| Smart Cull | local bounded analysis with score/recommendation/reasons |
| People / Face Groups | on-device Vision face detection + local feature-print clustering; persistent project groups and Library filtering |
| Cull views | Loupe / Compare / Survey + filmstrip/inspector |
| Persistent Cull cache | source-fingerprint/schema keyed disk cache |
| Developed-source cache | persistent float linear preview source cache |
| Adjusted-preview cache | persistent exact rendered-preview cache keyed by source/look/size |
| Custom cache location | macOS default, writable local volume, or mounted external drive |
| Cache controls | RAM policy, disk budget, path/status, reveal, per-store clear, Clear All |
| Memory pressure | warning trims; critical releases volatile preview caches |
| First paint / revisit | cached source or exact adjusted-preview presentation |
| Stale selection cancellation | generation/render-loop/decode cancellation |
| Latest-render-wins | one active render + one replaceable pending request |
| Working file | fixed 1080 px linear developed source reused for live and idle editing; original source only for Full Resolution Preview/export |
| Drag display | adaptive display-only proxy + latest-wins native refinement; never persisted as final adjusted preview |
| Committed preview | exact native renderer at configurable normal preview size |
| Full Resolution Preview | explicit full-source render |
| Studio UI | Library / Cull / Proofs / Edit / Export shell + three-pane editor |
| Scopes | dedicated waveform/parade/vectorscope-style inspector |
| Expanded tone stack | Exposure, Brightness, Contrast, Midtones, Highlights/Shadows, separate recoveries, Whites/Blacks, White/Black Point, curves |
| Tone curve libraries | Technical, Film Response, Creative |
| Relative WB recipes | As Shot/Auto-relative technical + Creative presets |
| Color Density | master + RGB/CMY controls |
| ProofDock client round-trip | short links, cover/password/limit, finish/regenerate, Client Picks sync |
| Export presets | High Quality, Fast Web, Instagram/Story/LinkedIn/X/YouTube |
| Exposure Warning | final rendered-image risk + hard-clip warning after all visible grading and geometry; never RAW-side |
| Skin Check | final-render subject-isolated overlay + scope with Too Green / On Target / Too Magenta agreement |
| Diagnostics excluded from export | separate analysis/viewer path, never part of `RenderLook` |
| JPEG / HEIC / TIFF8 / TIFF16 | verified `ExportWriter` path |
| Export verification | temp encode → ImageIO read-back → dimension/depth checks → atomic final move |
| Batch failure resilience | continues per file; reports failures |
| Intel macOS | x86_64-only release build |
| Required SDK | Local Xcode 26 / macOS 26 SDK |
| Runtime gate | Metal `--self-test` + `--studio-soak-test` |
| Production signing | Developer ID + hardened runtime + notarization + stapling + Gatekeeper |
| Native renderer | pinned `8f6651858f439a99b7202b4b8dea59e344dadf5d` |

## Validation in this package

- `swiftc -frontend -parse Sources/SpektraFilmFast/*.swift`
- `swift package dump-package`
- `python3 scripts/qa_production.py`
- `./scripts/qa_10_passes.sh`
- `./scripts/verify_source.sh`

The actual macOS compile/link/Metal runtime gate remains a local Intel x86_64 build with Xcode 26 / the macOS 26 SDK, followed by the manual checks in `PRODUCTION_QA.md`.
