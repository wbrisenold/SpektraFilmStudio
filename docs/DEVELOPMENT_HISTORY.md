# Development history

Consolidated on 2026-10-08. These dated implementation notes and earlier audit reports are preserved for provenance; they are not current build instructions. Use README.md and the focused guides beside this file for current behavior. Original filenames identify each archived section.

## Earlier README.md

# SpektraFilm Studio

**A photo library, culling, film-look development, and export workspace built around [spektrafilm](https://github.com/andreavolpato/spektrafilm).**

SpektraFilm Studio was made primarily to work with **spektrafilm's film stocks, print-paper simulation, and photographic-process controls**. It is **not** intended to imitate Lightroom's enormous all-purpose color grading interface. If you want to change the color grade, start with the **SpektraFilm film and print tools**, along with exposure, white balance, film color density, negative/print parameters, and local masks. A conventional independent color-grading module is intentionally not the point of this application.

I use it to **import → cull → develop RAW → shape the SpektraFilm look → export**, then move the selected portraits into **Adobe Photoshop for detailed skin/hair cleanup and portrait retouching**. SpektraFilm Studio handles the photographic base; Photoshop is my finishing step, not an embedded feature.

> **Upstream credit:** [Andrea Volpato's original spektrafilm](https://github.com/andreavolpato/spektrafilm) is the inspiration and reference for the physical photographic-process model. Please read and respect its GPL-3.0 source license, separate profile/data licenses, attribution requests, and [citation](https://github.com/andreavolpato/spektrafilm/blob/main/CITATION.cff). This Studio front end is a distinct community-oriented application; it is not the original project's official GUI.

## Why a dedicated SpektraFilm Studio?

A realistic film look comes from more than moving a hue or adding a preset. Original spektrafilm models the path from scene-referred camera data through a **virtual film negative, spectral sensitivities, dye density and development, enlarger/printing, and scanning**. Studio makes that process practical during a complete photo shoot without exporting each RAW through multiple tools. The aim is to explore those film/print relationships while retaining non-destructive editing and a photographer-friendly Library/Cull/Export workflow.

### First launch — five steps

1. **Library → Import Photos.** The Design A import assistant asks for a source (files, card/folder, Lightroom Classic `.lrcat`, or an existing iCloud library), storage mode (reference files, verified two-destination copy, or iCloud where supported), and review/confirmation. Importing doesn't overwrite your camera originals.
2. **Cull.** Check the best shots. Use `Analyze` to score focus, subject/face detail, exposure, noise and near-duplicates. Use **Best Picks → Folder → Keep percentage → Pick Best in Folder** to flag the strongest distinct photos. Filter by **Sharp Faces, Possible Blinks, Soft / Back Focus, Exposure Issues, High Noise, Burst / Duplicates, Unreviewed**, etc. Pick suggestions do **not delete** anything and respect rejected frames.
3. **Proofs (optional).** Make a ProofDock gallery from picks; send the client a link and bring their selections back into the Library. Proofing is an optional stage, not required to edit.
4. **Edit.** Prepare the RAW, choose the stock and print response, use film controls to establish the grade, then make any selective edits. The canvas is always the priority; presets, inspector, filmstrip, and scopes can be toggled.
5. **Export.** Choose full-res delivery or a named size/preset, verify fit/crop and color space, then export. From Edit you can also **Export This Photo** through the compact single-image dialog. For Photoshop portrait retouching, export a high-quality TIFF (16-bit where the selected export path supports it), open it in Photoshop, retouch, and deliver the final image there.

For a longer practical guide, see **[PHOTOGRAPHER_WORKFLOW.md](PHOTOGRAPHER_WORKFLOW.md)**.

## Film controls are the color-grading workflow

**Start with the physical pipeline rather than looking for a separate Color Grade tab:**

| When the image needs… | Work in… |
|---|---|
| Correct camera exposure, headroom and white balance | **Adjust → RAW / White Balance + RAW Develop**; use Apple RAW Exposure/Global Tone and the light controls |
| A different overall palette and tonal personality | **Film → stock selection and film-negative characteristics** |
| Print warmth, contrast, color cast or density | **Film → printing / paper / enlarger / scanning controls**, as available in the active renderer |
| Targeted color density by hue family | **Film → ME deSatch Color Density** (`Global`, `R`, `G`, `B`, `C`, `M`, `Y`) |
| More localized shaping | **Masks → Subject, Skin, Person, Background, Hair, Object, Linear or Radial**; select a mask to direct compatible adjustments at it; select Main Image to return to global edits |
| Optical falloff or character | **Lens Character** with a draggable center and indicated effect region |
| Confidence in exposure and color | Toggle **histogram, waveform, vectorscope, False Color, skin and clipping diagnostics** |
| A starting point or a saved personal look | **Presets**; hover for a temporary image preview; apply to edit |

Stock/print response is not the same as a generic LUT applied after exposure. The original project is a useful reference for learning each stage: [upstream README](https://github.com/andreavolpato/spektrafilm#readme).

### What's custom in Studio

- **Design A native macOS workspace:** photo-first SwiftUI/AppKit layout, contextual inspectors, hidden-on-demand preset drawer, resizable filmstrip, keyboard-friendly Cull and collapse-to-canvas editing.
- **RAW controls:** Apple RAW Exposure EV, RAW Global Tone, white balance including per-image As Shot/Auto bases, EDR/headroom, shadow/highlight controls. Film-stage Exposure EV and Auto Exposure remain in their native **Film** group and are **different** controls from RAW exposure.
- **Color Density:** ME deSatch cone-coordinate behavior inspired by [Moaz Elgabry's DCTL](https://github.com/MoazElgabry/DCTLs), with credits/licensing in the repository.
- **Local masks:** AI-assisted selection plus gradients and per-mask adjustments; one selected edit target. Auto skin overlays and diagnostic skin readings should use the same semantic selection logic.
- **Lens Character:** draggable optical center and visible falloff guides.
- **Diagnostics:** live False Color during interactions, scopes, skin and exposure clipping indicators. Monitoring overlays are viewer aids, **not** burned into normal photo exports.
- **Cull:** background metrics, burst comparisons, folder-specific **Best Picks**, issue filters, and heavier Apple Vision **face-capture quality and image-aesthetics models** for portrait and scene suggestions.
- **People:** local-only Vision face grouping with multiple face crops, cautious second-pass cluster consolidation, stable labels on rebuild and manual **Merge Into Person…**. These are similarity groups, not verified legal identities.
- **Client Proofs:** ProofDock short links, favorites, submission and selection return.
- **Lightroom/iCloud:** a **migration / iCloud Library implementation** that preserves original `.lrcat` material and stores originals, previews and edit journals in a selected iCloud Drive folder. Its real-world cross-device reliability must be tested before treating it as a sole photo archive.
- **Export:** non-destructive crop in Edit/Export, full-resolution pipeline, small single-photo export sheet, presets, format/color/metadata options and memory-aware concurrency controls.
- **Cache:** quick interactive preview/proxy, configurable disk cache location, explicit cache controls and separate final-quality export.

## Why it can feel slower than a LUT preset

**The correct explanation is not simply “it uses no LUTs.”** A quick creative 3D LUT mostly looks up pre-baked RGB values. The **SpektraFilm look** instead asks the renderer to evaluate stages of a photographic simulation: spectral/scene reconstruction, nonlinear film layer responses, negative density/development, print-paper and enlarger behavior, and sometimes grain, halation, optical effects and scanning. The exact cost depends on the selected stock/process/effects and the implementation.

Some *internal* reconstruction modes use lookup tables or bases to turn camera RGB into approximate spectra, and the upstream project includes a separate LUT-generation utility. **“Not a baked single-LUT look pipeline” is accurate; “absolutely no LUTs anywhere” is not.** See the upstream project's discussion of spectral reconstruction methods and LUT creation. <https://github.com/andreavolpato/spektrafilm>

Additional time comes from **RAW decoding/denoise; mask inference; multi-pass full-float/Metal processing; geometric transforms; tone/scopes; and full-resolution image encoding**. Studio therefore uses smaller interactive proxies and caches to keep slider movement responsive while a settled or exported frame uses the more expensive accurate path. The proxy should never be silently exported in place of the final full-res look. Long exports and crashes are defects to profile and fix, **not** unavoidable proof of authenticity.

The reference upstream project itself documents slow full-res simulation. Your speed will depend strongly on file megapixels, Intel CPU/GPU/VRAM, film options, and whether export can keep its memory within budget.

## Build and status

- Native **macOS 15+** application with **Intel `x86_64`** build workflow, using SwiftUI, AppKit, Apple Vision, Metal, native spectral engine, and selected open-source dependencies.
- See `BUILD_ON_MAC.command`, the repo build scripts, `AI_HANDOFF.md`, `FEATURE_AUDIT.md`, `IMPLEMENTATION_SOURCES.md`, and `PRODUCTION_READINESS.md` for exact build/dependency/QA details.
- This repository is experimental. The cumulative source patch's parser/static tests **do not** establish an Intel macOS runtime build, film/colorimetric parity, or production reliability. Keep the originals and a separate verified backup. Validate samples before trusting batch export or cloud migration.
- This application was built openly with substantial **AI-assisted / vibe-coded** iteration. Contributions, bug reports, real RAW test fixtures (with permission), performance profiles, feature proposals and reproducible fixes are welcome. Source acknowledgements and licenses are published rather than hidden.

## Attribution and contributing

Core concept: [andreavolpato/spektrafilm](https://github.com/andreavolpato/spektrafilm) ([upstream support](https://www.buymeacoffee.com/andreavolpato)). Related inspirations/implementations are credited in `IMPLEMENTATION_SOURCES.md` and `THIRD_PARTY/`. Please review each model, source, preset/profile and data asset's **individual license** before redistribution. A repository's code license does **not** automatically license all pretrained weights in it.

If you'd like to contribute: start with a testable issue, include app version, camera/RAW type, steps, expected and actual previews/exports, whether masks/denoise are enabled, and crash logs without private client images. Accuracy, cross-device cloud consistency, face-group review and memory-stable exports are priority areas.


---

## BLOAT_UI_OPTIMIZATION_AUDIT.md

# SpektraFilm Studio v0.6.8 — Bloat, UI, and Optimization Audit

Audited baseline: `95382058ad041a787bb232bc623134333226c95f`

## Applied in this cumulative patch

### Render/UI correctness
- Settled RAW Develop host-tone rendering no longer drops the tone stack.
- False Color/scopes receive the live interactive proxy instead of freezing during pointer movement.
- Mask selection is one model-level edit target; the overlay and local grade no longer maintain competing selected-mask state.
- Presets use a lighter list with accurate main-view hover preview instead of expensive/untrustworthy per-preset thumbnails.
- Lens Character uses a draggable real center with effect-boundary overlays.
- Export Preview keys include the active sizing/crop selection.

### Density
- Replaced the Primera-style tetrahedral density implementation with a Swift adaptation of the cone-coordinate behavior from `ME_Desatch.dctl`.
- Controls now match the DCTL's one-directional contract: `0 ... -1`.
- UI is Global, Red, Green, Blue, Cyan, Magenta, Yellow deSatch.
- Removed the extra Preserve Luminance UI because it is not part of ME_Desatch.
- Old positive density values remain decodable but normalize to identity under the new one-directional contract.

### Original Film controls restored
The consolidated UI had removed its dedicated Film Stock Exposure panel but still filtered these native controls out of the Film group:
- Exposure EV (`filmExposureEv`)
- Auto Exposure (`autoExposure`)
- Auto Exposure Meter (`autoExposureMethod`)

The stale filter is removed. These controls render again in their original native Film section. The native descriptor already defines Auto Exposure as a Boolean, so it returns as a checkbox/toggle.

### Single-photo export
- Filmstrip context menu gains **Export This Photo…**.
- It creates a one-item `ExportJob` and uses the exact same full-resolution renderer, resize, color, naming, and writer as normal Export.
- It does not disturb the photo's queued-for-export state or other queued photos.

### Dead / stale source removed
- `SemanticMaskPanel.swift` had no call site and duplicated the newer Mask panel plus a second persisted mask-selection state. It is removed.
- Stale `film-stock` inspector routing from the deleted dedicated Film Stock Exposure panel is removed.
- `AI_HANDOFF.md` workspace flow is corrected to the actual consolidated flow: Library → Cull → Proofs → Edit → Export.

### Build / dependency optimization
- `Rust/SpektraStudioCore/Cargo.toml` declared 11 direct LightCraft crates, while `src/lib.rs` only calls `lightcraft-develop`. The 10 unused direct dependencies are removed; Cargo still resolves whatever `lightcraft-develop` genuinely needs transitively.
- The LightCraft bootstrap no longer performs a network fetch every build when the pinned commit is already checked out locally.
- Release packaging no longer executes `rm -rf dist`. It only replaces the current `.app` and current-version ZIP/checksum/build-info, preserving older artifacts in `dist/`.
- ME_Desatch provenance is copied into the packaged app's Licenses directory.

## Deliberately not removed

### AI model/runtime bundle
The ONNX runtime and mask models are large, but they directly support the improving automatic masks the app currently depends on. Removing them would be a feature regression. A future size-focused release can move optional segmentation models into install-on-demand model packs.

### Serialized `filmTone`
`filmTone` is still decoded/applied for compatibility with projects created while the separate Film Exposure Shape panel existed. Deleting it now can alter saved looks. It should only be removed through an explicit project migration with visual equivalence tests.

### LightCraft source checkout
Fresh clean builds still need the pinned LightCraft checkout because the unified core genuinely consumes `lightcraft-develop`. This patch eliminates repeated fetches and unused direct crate compilation. Making the repository completely network-independent would require committing/vendor-packaging the pinned required source subtree rather than silently cloning it.

## Structural hotspots

Largest Swift source files in audited HEAD:
- `AppModel.swift`: 213,655 bytes
- `ControlsView.swift`: 65,286 bytes
- `ProjectModels.swift`: 49,160 bytes
- `ToneGradeEngine.swift`: 36,741 bytes
- `ProofDockService.swift`: 34,997 bytes
- `LibraryView.swift`: 31,184 bytes
- `ScopeEngine.swift`: 30,769 bytes
- `ExportView.swift`: 28,296 bytes
- `ImageDecoder.swift`: 28,280 bytes

`AppModel.swift` is the main maintainability/compile-time hotspot. Splitting it into focused `AppModel+Render`, `+Export`, `+Masks`, `+LibraryCull`, and `+Persistence` extensions would improve incremental development, but doing that during this functional repair would create high churn without runtime benefit. It is therefore recorded as the next safe refactor rather than mixed into this patch.

## UI decisions

The audit favors fewer competing surfaces:
- one Mask workflow instead of MaskPanel + SemanticMaskPanel;
- native Film controls in their real Film group instead of a duplicate Film Stock Exposure panel;
- list presets instead of a thumbnail wall;
- one-photo export in the filmstrip context menu rather than another permanent toolbar;
- density controls restricted to the exact ME_Desatch contract instead of carrying unrelated luminance options.



---

## CULL_FACE_ACCURACY.md

# Face grouping and cull accuracy — implementation notes

## Face grouping v2

- More detailed 1600px thumbnails for grouping; face bounding boxes from Apple Vision.
- Two crops per detected face (tight face + wider context) generate comparable Vision image-feature embeddings.
- First pass ranks representative distances, with per-cluster consensus rather than first matching any prior face.
- A second, guarded pass attempts to merge pose/lighting split clusters when multiple independent photo comparisons support them.
- Prevents identities that co-occur in one photograph from being automatically merged.
- Preserves stable group names and IDs on rebuild when groups have at least two overlapping photo IDs; user can manually merge remaining split folders.
- Face samples stay local. No client face images or embedding data are sent to a third-party server.

**Limitations:** `VNGenerateImageFeaturePrintRequest` produces a general image-similarity embedding, not a trained identity-verification vector. Multi-crop and clustering improves consistency but is not equivalent to ArcFace/FaceNet. Similar-looking people can be confused, and hard side profiles may stay split. The thresholds must be validated on mixed group photos before treating grouping as reliable. Manual merges are corrections, not proof of identity.

## Stronger portrait culling

- Keeps existing thumbnail technical metrics and duplicate-stack logic.
- Adds native trained **Apple Vision `VNDetectFaceCaptureQualityRequest`** (portrait quality) and **`VNCalculateImageAestheticsScoresRequest`** (scene aesthetic score, -1...+1) for two extra learned signals. They are combined with the existing technical metrics, with a modest weight to avoid silently rejecting creative photos. The values are saved as optional backward-compatible fields in `CullAnalysisRecord`.
- Reuses cached metrics for filtering: sharp faces, possible blinks, soft/back focus, aesthetic quality, exposure issues, noise, duplicate bursts and unreviewed images.
- `Pick Best in Folder` chooses up to the requested fraction from analyzed eligible photos, ranked by technical score, face sharpness, face capture quality, possible blink and clipping penalties, with burst deduplication. It never deletes originals or overrides a rejected photo. Choosing All Folders applies the fraction independently to each folder.
- If the folder has missing cull records it runs the existing bounded background analysis first, then applies picks.

## Open-source alternatives reviewed

- [OpenPhotoCull](https://github.com/zwoodard/OpenPhotoCull) — MIT-licensed subject-aware focus, face/eye checks, exposure, duplicate/burst and configurable filters, documented publicly. Useful architecture without importing its React/Tauri UI into SwiftUI.
- [OpenCV Zoo SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) — stronger identity-specific embedding option, model directory declares Apache-2.0. However, face model training data/weight commercial provenance has a live clarification issue; cannot responsibly claim all distribution/inference rights from code license alone. Not bundled in this patch.
- [InsightFace](https://github.com/deepinsight/insightface) — excellent recognition technology, but bundled/automatically fetched pretrained models are generally non-commercial research use without additional licensing. Not bundled.
- Apple's bundled Vision framework works natively on Intel and requires no extra model redistribution, so this release uses its image-feature and face-quality requests for immediate improvements while leaving room for a later appropriately licensed biometric model.

## Before shipping

On the Intel Mac, test real multi-person wedding/portrait sets for false merges, split identities, face occlusion and alternate lighting; compare before/after grouping; validate the culling threshold by selecting and manually reviewing 500+ diverse photos. Confirm the actual macOS Swift type-check and `VNDetectFaceCaptureQualityRequest` behavior. Source/parser tests alone do not prove identity accuracy.


---

## DESIGN_A_IMPLEMENTATION.md

# Design A implementation — Native Pro Studio

- Text-only project menu; app icon no longer occupies the left toolbar.
- Native five-workspace navigation, including existing Proofs.
- First-run empty Library opens a guided source/storage/review import wizard.
- One persistent `Import Photos…` action; advanced import actions move into a menu.
- Library inspector is opt-in instead of always consuming ~280 points.
- Edit defaults to presets hidden; toolbar can show/hide presets, filmstrip and inspector.
- Adjust / Film / Masks contextual inspector tabs; all controls remain accessible.
- Scope and clipping monitor collapses; render math and native scopes unchanged.
- Geometry, RAW Exposure EV, Auto Exposure, ME deSatch and masking maintain existing controls.
- Verified ingest wizard calls the existing resumable SHA-256/primary/backup service.
- Lightroom wizard selects .lrcat once and passes that source directly to cloud migration.
- Cloud wizard opens selected existing .sflibrary without duplicate source selection.
- Unmodified: RAW processing, Metal renderer, export writer, AI models, presets math.

Build tests require a real macOS Intel/Xcode environment.


---

## DIAGNOSTIC_OPEN_SOURCE_REFERENCES.md

# Skin / diagnostic open-source references

## ScopeWalker
- https://github.com/ScopeWalker/ScopeWalker
- License: CC0 1.0
- Used concept: vectorscope YUV math and flesh/skin-line direction.

## Kdenlive
- https://kdenlive.org/
- Used concept: I-line / skin-tone-line correction workflow.
- No Kdenlive source is copied.

## SpektraFilm renderer
- https://github.com/chaert-s/spektrafilm-ofx
- Used as the source of truth for output color-space indices and SDR transfer behavior.

The Swift implementation in this patch is written specifically for SpektraFilmFast.


---

## EXPORT_AND_INTERACTION_PERFORMANCE.md

# SpektraFilmFast v0.5.3 performance changes

- Continuous slider/WB/density motion no longer queues the exact spectral renderer.
- Pointer motion uses the existing 1080p display proxy; one exact preview runs after settle.
- Static filename templates receive a sequence suffix so batch files cannot overwrite each other.
- Duplicate expanded names are disambiguated inside the batch.
- Export pre-decodes one image ahead when the pair is <= 60 MP total; large files fall back to serial decode to protect RAM.
- JPEG/HEIC/8-bit TIFF validation uses ImageIO properties instead of decoding pixels.
- 16-bit TIFF keeps one real decode to verify actual bit depth.
- The final moved file is checked by byte count rather than decoded a second time.
- Build is x86_64 only.
- SwiftPM incremental state is retained.
- The pinned native core/profile generation is cached between normal builds.
- Release executable symbols are stripped.
- Runtime spectral/Metal resources are kept because the renderer loads them at runtime.

A true end-to-end GPU-resident viewer still requires changing the native renderer interface so it can hand an MTLTexture directly to the viewer. This patch removes the largest interaction stall without pretending that CPU PixelBuffer/CGImage presentation has already been eliminated.


---

## FEATURE_AUDIT.md

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


---

## GPU_PORTING_AUDIT.md

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


---

## OPEN_SOURCE_PIPELINE_AUDIT.md

# Open-Source Pipeline Audit — SpektraFilmFast

Target revision: `8aa1b47a4fd744d69736adfdfc139be8ca9029dd`

This audit is stage-specific. No single open-source photo app is strongest at
every part of the workflow.

## Library / DAM

Primary reference: **darktable lighttable**.

SpektraFilmFast already has Albums, Smart Collections, People grouping, ratings,
flags, labels, XMP, managed ingest and batch edit/export selection. The useful
change is integration rather than duplicating Cull: Library remains the source
of truth for organization, filter, selection and batch operations, including a
new Export Queue filter.

## Cull

Primary workflow reference: **darktable culling / preview modes**.

Cull is now a decision workspace:
- Loupe;
- synchronized Compare;
- Survey;
- navigation across either the visible Library result or highlighted Library set;
- fast Pick / Reject / rating / color label;
- Smart Cull score, face/focus/exposure/blink detail;
- resizable no-crop filmstrip.

It does not become a second Library.

## Export

UX reference: **RapidRAW**.
Workflow reference: **darktable export**.

The page now separates:
1. export-set construction;
2. delivery/color intent;
3. destination;
4. file naming + preflight;
5. format/quality;
6. dimensions;
7. metadata/privacy;
8. queue/recovery.

## RAW / white balance

Primary implementation: **Apple CIRAWFilter**.

Settled RAW As-Shot/Auto relative offsets now remain in camera-space RAW
development whenever a reliable camera-space path exists. The working-space
Rec.2020 matrix remains a live-drag proxy and non-RAW/Auto-fallback mechanism.

WB-to-Skin probes the exact committed RAW path so it cannot choose a correction
from the approximate drag proxy and then settle to a different green/magenta cast.

Printer lights / print filtration remain creative printing controls; they do not
replace capture white balance.

## Skin diagnostics

References: **Primera Skin + Apple Vision isolation**.

The false-color overlay, skin percentages, centroid and skin vectorscope now
derive from the same refined final-output skin mask. A mixed-light state is
reported when meaningful green-side and magenta-side skin regions cancel in the
mean centroid.

## Film / print simulation

Source of truth: **current Spektrafilm**.

Current upstream Spektrafilm exposes named internal taps such as:
- `log_e_film`
- `cmy_film`
- `log_e_print`
- `cmy_print`
- `rgb_out`

Its LUT creator supports multiple topologies. That confirms the fast path should
be split around physical spatial stages rather than replaced by one end-to-end
LUT.

Spatial stages remain real:
- halation / light scattering;
- density-dependent grain;
- diffusion / bloom;
- scanner blur / unsharp;
- spatial DIR behavior.

## Color delivery

For web/phone/social delivery, the new `sRGB · Web / Phone` mode changes the
renderer output transform to actual sRGB before encoding. It does not merely
retag Rec.709 Gamma 2.4 pixels with an sRGB ICC profile.

`Match Renderer` remains available for controlled master workflows.

## Export performance

The new bounded conveyor is:

`decode N+1  ||  exact GPU render N  ||  encode/write N-1`

Decode-ahead is admitted from `os_proc_available_memory()` and an estimated byte
cost instead of the old 45 MP pair ceiling.

Float32 RGBA -> UInt8 / UInt16 conversion is vectorized with Accelerate/vDSP in
bounded chunks. The TIFF16 writer no longer re-decodes every just-written
full-resolution file merely to re-check bit depth.

The existing per-stage CSV timing log remains the measurement source.

## LUT fast path

The exact renderer remains the correctness and export reference.

The included `scripts/lut_feasibility.py` is the required stop gate before
enabling a LUT renderer:
- generate 33^3 / 65^3 identity cubes;
- verify R-fastest `.cube` ordering;
- compare exact vs candidate float outputs;
- report per-channel errors, RMSE and DeltaE2000;
- gate on measured fidelity.

No unmeasured LUT approximation is silently enabled.

## Architecture

The shipping architecture remains **Intel x86_64 only**.
No arm64 / Universal changes are made.


---

## PERFORMANCE_AUDIT.md

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


---

## PRODUCTION_HARDENING_V0.6.md

# SpektraFilmFast v0.6 production-hardening changes

This release is layered on the v0.5.4 skin/diagnostic/WB-to-Skin work.

Core hardening:
- real macOS memory-pressure callback reaches the cache-shedding path;
- critical pressure releases full-resolution/transient buffers instead of retaining them;
- import metadata hydration updates only imported records instead of copying/rescanning the entire project every batch;
- autosave snapshots are captured only after the debounce expires, avoiding a full project copy on every slider/project mutation;
- people grouping and proof generation are cancellable and guarded by project generation;
- burst stacks require real capture timestamps and both temporal + visual proximity;
- managed ingest copies to primary and backup with streaming SHA-256 verification and a crash-resumable journal;
- Library gets verified Ingest/Resume/Stop controls;
- batch edit sync supports preserving per-photo WB and crop, including full-look sync when desired;
- export becomes a durable queue with preflighted filenames, hard Stop, retry, crash resume, and no silent overwrite;
- static filename templates always auto-number multi-file batches;
- ExportWriter refuses to replace an existing file even if another layer makes a mistake;
- v0.5.4 colorspace-aware skin diagnostics and WB-to-Skin remain intact.

Production approval still requires the exact Intel build plus real RAW/wedding-scale soak tests on macOS.


---

## PRODUCTION_QA.md

# Production QA — v0.5.1

`./scripts/qa_10_passes.sh` performs source-level regression passes. **A local Intel x86_64 build using Xcode 26 / the macOS 26 SDK remains the compile/link/Metal gate.** Run the checks below on the built `.app` before release.

## 1. Library / import

- Import 1, 100, 1,000, and, if available, several thousand mixed JPEG/HEIC/TIFF/RAW files.
- Verify first Library paint is not blocked by EXIF/full rendering.
- Verify RAW thumbnails prefer embedded previews when available and persist across relaunch.
- Verify search, sort, folder filters, albums, saved smart collections, ratings, flags, color labels, batch actions, and export inclusion.
- With Auto Smart Cull enabled, verify imported photos begin analysis after thumbnail warmup without freezing Library interaction.
- Enable automatic XMP writes and verify rating/flag/color changes update sidecars; disable it and verify no automatic sidecar write occurs.

## 2. Cull

- Exercise Loupe, Compare, and Survey.
- Analyze a selection and verify progress/cancel, scores, recommendation, focus/exposure metrics, face metrics where detected, stack rank, and reasons.
- Relaunch and verify cached analysis is reused for unchanged source files.
- Confirm Smart Cull never deletes originals or silently applies destructive decisions.

## 3. Cache location and persistence

- Use the default cache and Reveal in Finder.
- Choose another writable local volume, then a mounted external drive; verify the visible `SpektraFilmFast Cache` folder is created at the selected parent.
- Disconnect the external drive and verify the app reports the cache unavailable rather than silently changing the selected custom path.
- Reconnect and verify cache operation resumes.
- Test individual clearing of Thumbnails, Developed Sources, Adjusted Previews, and Smart Cull, plus Clear All.
- Verify disk budget and RAM policy changes do not alter originals or project files.

## 4. Slider / preview behavior

On JPEG and camera RAW:

- Drag RAW Temperature/Tint and representative Color, Film, Print, DIR, Grain, Halation, Diffusion, and Scanner controls.
- Confirm pointer motion stays responsive and no native-render backlog accumulates.
- Confirm mouse-up commits project state once and schedules the exact configured normal preview.
- Confirm the transient interaction proxy is replaced by the exact committed preview and is not reused as the settled adjusted-preview cache entry.
- Set Working File to multiple values and verify ordinary edits reuse the developed working representation instead of redeveloping the RAW on every slider move.
- Set Live Edit Render to 1024, 1280, 1536, and 2048 and verify there is no hidden 720/768 fallback.
- Set Normal Preview to multiple values (for example 1024, 1800, 2560) and verify committed preview dimensions follow the setting rather than a hidden fixed cap.
- Enable Full Resolution Preview and verify it explicitly renders the source at full resolution; turn it off and verify return to the configured normal preview.
- Switch Library → Cull → Edit and between photos; the selected image/look must render without requiring a slider nudge.

### Expanded tone controls

- Exercise Exposure, Brightness, Contrast, Midtones, Highlights, Shadows, Highlight Recovery, Shadow Recovery, Whites, Blacks, White Point, and Black Point independently.
- Verify every slider has a working individual reset and Reset Section returns the entire tone section/curve to neutral.
- Verify Technical, Film Response, and Creative curve presets change only the host tone curve and remain non-destructive.
- Verify Creative WB presets start from the selected image's resolved As Shot or Auto base rather than forcing a fixed Kelvin/tint.

## 5. Auto White Balance

- Test JPEG and multiple camera RAW files under daylight, tungsten, mixed light, and intentionally warm/cool scenes.
- Verify Auto WB actually changes the image when appropriate, Recalculate runs again, and switching into Edit does not require moving another control before the result appears.
- Verify final committed preview/export uses the exact RAW path.

## 6. Scopes and diagnostics

- Test histogram/waveform/parade/vectorscope/skin-vectorscope/CIE inspector modes and scope refresh setting.
- On detected skin, deliberately push Tint toward green and magenta and verify both the viewer overlay status and Skin Vectorscope agree on Too Green / On Target / Too Magenta.
- Verify the Skin Vectorscope shows measured and target markers plus the connector when confidence is sufficient.
- Verify Exposure Warning and Skin Check update the viewer only and never modify `RenderLook`.
- Confirm Before view and exports contain no diagnostic overlay pixels.
- Confirm UI copy does not claim true RAW sensor/photosite clipping.

## 7. Export regression

For JPEG, HEIC, TIFF8, TIFF16:

- one-file and batch export;
- output dimensions match full-resolution render;
- TIFF16 reports 16 bits/component;
- metadata/orientation behavior matches settings;
- deliberate one-file failure does not abort the remaining batch;
- output read-back verification succeeds before success is reported;
- scopes/diagnostics never appear in exports.
- Exercise High Quality, Fast Web, Instagram, Story/Reel/TikTok, LinkedIn, X, and YouTube presets; verify resize/don't-enlarge/metadata behavior matches each preset.

## 8. Project recovery / compatibility / relink

- Open older projects/presets and verify migration/defaults.
- Save/reopen and verify source paths, ratings, flags, labels, albums/smart collections, looks, Cull results, and export settings.
- Force-terminate after edits and verify recovery prompt behavior.
- Move a source folder and test recursive Relink with duplicate-name ambiguity.
- Trigger memory pressure if practical and confirm volatile caches can be released without project/original loss.

## 9. Build / distribution

- Run `BUILD_ON_MAC.command` from this exact source package and verify it completes the Intel x86_64 build.
- Metal `--self-test` and `--studio-soak-test` pass on the locally built Intel x86_64 app.
- `lipo -archs` contains `x86_64`; arm64 is not required.
- Info.plist version is `0.5.1`.
- Release build has Developer ID Application authority + hardened runtime.
- Apple notarization, stapling, and Gatekeeper assessment succeed.
- Release ZIP and `SHA256SUMS.txt` verify after an independent download.

Notarization is automated by `scripts/notarize.sh`; see `RELEASING.md` for the
one-time Apple Developer setup. `./scripts/notarize.sh --check` reports exactly
what is outstanding. Until it has run, a release is ad-hoc signed, and the
Gatekeeper workaround in `RELEASING.md` §3 is mandatory in the release notes.

### 9a. Publishing a GitHub release (after each build)

Repeat this every time the app changes, so people can download the app instead of
building it. See `RELEASING.md` for the full checklist.

```bash
# 1. Build clean, so the published artifact is reproducible from the commit.
#    (SPEKTRAFILM_CLEAN=1 forces a from-scratch build and sets incremental_build=no.)
SPEKTRAFILM_CLEAN=1 ./BUILD_ON_MAC.command

# 2. Sanity-check the artifact before publishing anything.
codesign --verify --deep --strict dist/SpektraFilm.app
lipo -archs dist/SpektraFilm.app/Contents/MacOS/SpektraFilm      # expect x86_64
grep incremental_build dist/build-info.txt                        # expect incremental_build=no
unzip -t dist/SpektraFilm-*.zip                                   # expect No errors

# 3. Tag the exact commit you built, and publish.
git rev-parse --short HEAD            # record this; the release must point at it
gh release create v<VERSION> \
  dist/SpektraFilm-<VERSION>-macOS-intel.zip dist/SHA256SUMS.txt \
  --target main \
  --title "SpektraFilm <VERSION> — Intel (x86_64) macOS app" \
  --notes-file RELEASE_NOTES.md

# 4. Confirm the published bytes match what you built.
gh release download v<VERSION> --pattern '*.zip' --dir /tmp/relcheck
shasum -a 256 /tmp/relcheck/*.zip dist/SpektraFilm-<VERSION>-macOS-intel.zip
```

Release notes must state the Gatekeeper workaround, because the local build is
ad-hoc signed and not notarized. See the "first open" section of `RELEASING.md`.

The tag must point at the commit that was built, so `git rev-parse v<VERSION>^{commit}`
must equal `git rev-parse origin/main`. Do not move a published tag; publish a new version instead.

## 10. Studio soak

Run at least a one-hour real edit/cull/export session with repeated photo switching, Cull analysis, cache hits, scopes, RAW edits, and exports. Watch for runaway RAM/thread count/CPU after idle, stale-frame flashes, blank previews, or UI hangs.


---

## PRODUCTION_READINESS.md

# v0.6 production-hardening status

The source now includes verified dual-destination ingest, project-scoped background jobs,
large-import/autosave fixes, durable export recovery/Stop, batch look sync, memory-pressure
shedding, and the v0.5.4 skin/diagnostic/WB-to-Skin work.

**Production approval still requires the exact Intel macOS build, runtime tests, disk-full/
disconnect tests, crash-recovery tests, and a multi-thousand-RAW wedding-scale soak.**

# Production Readiness Matrix — v0.5.1

| Audit item | v0.5.1 disposition | Gate |
|---|---|---|
| Library workflow incomplete | Completed search/sort/folders/albums/smart collections/batch decisions/XMP/export inclusion | source QA + manual Library QA |
| Cull workflow incomplete | Completed local bounded analysis + Loupe/Compare/Survey + persistent result cache | source QA + manual Cull QA |
| Auto-cull preference disconnected | Wired import completion to targeted Smart Cull analysis | source QA + import QA |
| Auto-XMP preference disconnected | Wired rating/flag/color changes to optional XMP writes | source QA + XMP QA |
| Old sub-1K live-preview path produced unreliable results | Replaced with persistent fixed 1080 px linear working files for both live and idle editing | source QA + slider QA |
| Transient proxy could be mistaken for settled output | Proxy is display-only and not persisted as adjusted preview | source QA + visual settle QA |
| Cache location/control incomplete | Custom local/external folder, visible status/path, reveal/default, per-store clear/all clear | source QA + removable-drive QA |
| Cache schema could reuse stale approximation entries | Developed/rendered schema generations bumped | source QA |
| UI branches diverged | Newer studio shell merged into v0.4 Library/Cull/cache feature branch | source QA + manual UI QA |
| Scopes crowded edit controls | Dedicated Scopes inspector | manual UI QA |
| Auto WB regression risk | Functional v0.4 Auto WB/recalculate path retained | source QA + RAW/JPEG visual QA |
| Export contamination by diagnostics | Diagnostics remain separate from `RenderLook` / `ExportWriter` | source QA + export QA |
| Intel x86_64 binary/runtime not provable on Linux source host | Intentionally unresolved here | Local Xcode 26 / macOS 26 SDK Intel x86_64 build |
| Distribution trust | Developer ID + hardened runtime + notarization/stapling/Gatekeeper required | Local Mac release gate |

## Release status

This source tree is ready for the macOS build/runtime gate, not a claim that a final signed `.app` has already been executed in this Linux environment. The release commit must pass source checks, Universal compile/link, Metal self-test and renderer soak, signing/notarization, and `PRODUCTION_QA.md` before being called studio-production-ready.


---

## QA_10_PASS_REPORT.md

# v0.5.2 — Ten-pass production-source QA report

`./scripts/qa_10_passes.sh` covers these source-level gates:

1. Swift syntax and SwiftPM manifest.
2. Shell/workflow syntax and release prerequisites.
3. Pinned native renderer/resources and known release pitfalls.
4. Library import, persistent thumbnails, albums/smart collections, XMP hooks.
5. Smart Cull engine/workspace, bounded analysis, and persistent Cull cache.
6. Persistent working-file/edit contract: no sub-1K fallback, no persisted transient interaction frame, expanded tone controls, latest-render-wins scheduling.
7. Developed-source/adjusted-preview caches, cache-location controls, disk budgeting, and memory pressure.
8. Auto WB, scopes, Exposure Warning, and Skin Check integration.
9. Export isolation and verified JPEG/HEIC/TIFF8/TIFF16 paths.
10. v0.5.2 version/resource/source-manifest/runtime-distribution gates.

These source checks do not substitute for a local macOS 26 SDK Intel x86_64 build, the Metal self-test/renderer soak, Developer ID signing/notarization, or the real studio soak described in `PRODUCTION_QA.md`.


---

## REDLAMP_DESIGN_AUDIT.md

# Redlamp reference audit — 2026-10-08

Reference: [pdcgomes/redlamp](https://github.com/pdcgomes/redlamp), inspected at `0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd`. This is an interaction and visual hierarchy study, not an engine migration or a copy of Redlamp's code or artwork.

Evidence reviewed: the repository's `docs/images/hero.png`, `packages/RedlampDesign/Sources/Tokens/Metrics.swift`, `Typography.swift`, `Controls/PanelSectionView.swift`, `packages/RedlampUI/Sources/Inspector/AppKit/InspectorPanelsView.swift`, and `docs/plans/2026-10-01-export-design.md`.

| Finding in SpektraFilmStudio | Revision |
| --- | --- |
| Adjust/Film/Masks tabs lead into another RAW or film stage selector. Controls disappear behind nested categories. | Preserve the Develop, Film, and Masks tabs the user prefers. Each tab has discoverable collapsible sections, without an additional RAW or Stock/Negative/Print/Output category selector. Existing processing order and bindings remain intact. |
| Large stacked slider labels, card borders and technical explanations compete with the image. | Compact inline label/track/value rows, flat panel divisions, smaller system type and shorter photographic labels. Help retains technical context. |
| Export can choose the same destination in the toolbar, destination section and footer. | Exactly one destination chooser in its section. The footer only exports, and stays disabled until a destination and photos exist. |
| Guided import asks users to choose categories before requesting their source. | The source browser opens immediately on presentation. Changing source type immediately requests that browser. A compact source menu replaces four large tiles; optional storage remains on one sheet. |
| Cloud setup uses Next/Back through five pages. | Direct local-library actions, with optional server configuration in a disclosure on the same scrollable screen. |
| Heavy navigation capsules add another layer of visual chrome. | Retained workspace navigation with a quieter background and clear selected state. |

The useful lesson from Redlamp is hierarchy: large photo, restrained chrome, consistent dense controls and a visible panel list. SpektraFilmStudio keeps its Library/Cull/Proofs/Edit/Export workflow and its own film engine. No third-party source was ported.

Validation must include native compact/wide captures, an expanded film panel, immediate guided-source presentation, and the single export-location source gate. The delivery report records actual outcomes and limitations; the reference's Apple Silicon/macOS 26 requirements do not change this project's Intel/macOS 15 build contract.

## Small object model replacement

Redlamp's small object selector is Apple's Apache-2.0 Core ML conversion of Meta SAM 2.1 Hiera Tiny (79,644,968 bytes across nine model files), not a universal semantic part classifier. Spektra now uses the same model, pinned to Hugging Face revision `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306`, with checked byte counts and SHA-256 hashes. The inference adapter was independently implemented for Spektra, including Intel-safe tensor indexing and one-photo embedding reuse. Actual testing found non-finite output from the fp16 model on this Intel GPU; Intel uses Core ML CPU execution, while Apple Silicon uses CPU/GPU. No Redlamp SAM source was copied.

MobileSAM, BiRefNet and MODNet are excluded from the packaged app. Subject/background and people use Apple Vision. Existing specialized face/body parsers remain for skin, hair, eyes and clothing; SAM does not supply those labels. Original local model files are preserved. The nine model files download once during preparation and are then cached; the app contains compiled models and never uploads photos or downloads models during editing. The model's Apache licence is included.

`python3 scripts/prepare_sam2.py --check-only` verifies the cached model files. `--sam2-smoke-test --sam2-fixture /path/to/Meta/truck.jpg` exercises real inference, nonuniform coverage, foreground/background orientation, repeat prompts and invalid input. Runtime evidence is recorded separately from compilation.


---

## STAGE_1_EXPORT_ARCHITECTURE.md

# Stage 1 — Export Architecture

The exact film renderer is unchanged.

Pipeline:

decode N+1
    ||
exact GPU render N
    ||
bounded post-render pool for N-1 / N-2 / ...

The post-render pool owns:
- geometry
- export resize
- float-to-image conversion
- metadata
- compression
- verification
- atomic commit

Worker ceiling: 4.

Actual concurrency can be lower because the memory byte budget wins over
the worker ceiling for large Intel-Mac images.

`ExportEngine` is now a Sendable value type instead of an actor. The old
actor method was synchronous internally and therefore serialized ImageIO
encoding even when detached tasks were used.

Crash/recovery still relies on `.writing` queue state and atomic destination
commit. Stop cancels and drains in-flight post-render work before saving the
stopped journal.


---

## STAGE_2_MASK_LAYER_CORE.md

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


---

## STAGE_3_AI_CANONICAL_MASKS.md

# Stage 3 — AI / Canonical Semantic Masks

Implemented:
- MODNet subject/background matte;
- SCHP LIP-20 person, clothing, arms, legs, shoes and hair masks;
- CelebAMask-HQ BiSeNet facial skin, hair, eyes, lips and neck/body-skin masks;
- one cached CanonicalSemanticMaskSet per source image;
- canonical Skin Only subtracts hair, eyes, lips, clothes and shoes, then intersects person;
- Skin Overlay, Skin Vectorscope, skin statistics and Auto Skin WB receive the same canonical raster mask;
- semantic masks are inserted into the Stage 2 RasterMaskPayload path and therefore inherit Add/Subtract/Intersect, invert, opacity, feather and project persistence;
- ONNX Runtime universal2 keeps the inference path Intel-safe and Apple-Silicon-capable.

Object selection:
- Select Object / Add Object / Subtract Object use macOS Vision foreground-instance masks from a click point and write the result into the same Stage 2 raster stack.
- MobileSAM remains documented as the open-source prompted-object backend candidate; Stage 3 does not falsely claim it is the active runtime provider.


---

## STAGE_4_RAW_QUALITY_MONITORING.md

# Stage 4 — RAW Quality + Monitoring

- RawForge 0.2.4 RAW/CFA denoise cache (MIT), with Auto ISO-derived or Manual luma/chroma strengths.
- Denoise output is a cached DNG consumed by the normal decoder; no post-render blur substitution.
- Saturation scope and image-space false-color exposure monitor remain off the render-critical path and analyze the published 1080 px frame.
- Render, semantic-mask, and RawForge DNG caches are isolated and separately clearable/validatable.
- Lens Character section: 35mm Spherical, 50mm, 85mm, 28mm, Anamorphic 2x, Petzval, Vintage 58mm plus Custom controls for distortion, CA, highlight CA, spherical aberration, Petzval swirl, edge softness, vignette.
- Exact film core is untouched; lens character runs after film color and before crop/geometry.
- Stage 3 canonical Skin Only contract remains unchanged.


---

## STAGE_5_PRODUCTION_HARDENING.md

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


---

## SWIFT6_BUILD_HANDOFF.md

# SpektraFilm v0.6.0 — Swift 6.2 Build Handoff

Exact pinned build: app commit `c3a1030e52083d5865f05f9165cfb3702e4d303f`,
native core commit `8f6651858f439a99b7202b4b8dea59e344dadf5d`.
Toolchain used: macOS 15.7.9, Swift 6.2.4, `x86_64`, Command Line Tools only
(no full Xcode installed).

Run everything through `./BUILD_EXACT_GITHUB_V0.6.command`. Do not hand-edit the
checkout: the script resets it to the pinned commit on every run and re-applies
`v0.6.0-swift6-fixes.patch`. Local edits that are not in that patch are silently
destroyed.

## Why this file exists

The v0.6.0 tag shipped in early 2026 and does not compile on a Swift 6.2
toolchain. It compiled on the Xcode 26 / macOS 26 SDK the author used, so the
breakage only appears on machines that are otherwise fully supported. Five
distinct problems had to be fixed, plus three latent bugs that the repo's own QA
script was already designed to catch but had itself drifted out of date.

The fixes live in `v0.6.0-swift6-fixes.patch` and are applied automatically.
This document records *why* each one exists so nobody re-derives it or
"simplifies" it back out.

## 1. Local edits were being destroyed by the build script

**Symptom:** fixes were applied, verified to compile, then vanished on the next
builder run. Source showed as pristine even though compilation had previously
passed with it patched.

**Cause:** `BUILD_EXACT_GITHUB_V0.6.command` runs
`git reset --hard <commit>` before building. Anything not committed or otherwise
re-applied is lost. This cost several cycles of "re-apply, verify, run builder,
discover it is gone."

**Fix:** the four Swift fixes are stored as a patch file and applied with
`git apply` immediately after the reset. The script also asserts the checkout is
clean *before* applying, and afterwards that the only modified files are the six
expected ones — so an unexpected local edit fails loudly instead of being
destroyed.

## 2. `rtk git diff` does not produce an applicable patch

**Symptom:** `error: No valid patches in input (allow with "--allow-empty")`
followed by `ERROR: Swift 6 fix patch does not apply`.

**Cause:** `rtk git diff` emits a condensed, stat-style summary for the model to
read, not a unified diff. The generated "patch" had ~644 bytes and no `diff
--git` / `@@` hunks, so `git apply` had nothing valid to parse. It is a display
wrapper, not a plumbing command.

**Fix:** generate patches with plain `git diff` (or
`git diff --binary > patch`). Never redirect `rtk` output to a file that another
tool must parse. Always confirm with
`git apply --check <patch>` before relying on a patch file.

## 3. Nested `async` function lost `@MainActor` inside a `Task`

**File:** `Sources/SpektraFilmFast/AppModel.swift`
**Error:** `actor-isolated property 'filmOutput' can not be referenced from a
Sendable closure` / calls to main-actor state escaping into a non-isolated
context.

`sample(mired:tint:)` is declared `async` inside a `Task { }` body in a
`@MainActor` type. Being `async` does **not** inherit the enclosing actor
isolation — an `async` function is *nonisolated* by default, so it silently left
the main actor and could not touch `filmOutput` or other main-actor state.

**Fix:** mark it explicitly:

```swift
@MainActor func sample(mired: Double, tint: Double) async throws -> (Double, StudioAnalysisMetrics, RawSettings) {
```

The rule: **inside a `Task`, an `async` function does not inherit actor
isolation. Write `@MainActor` explicitly on every one.**

## 4. `??` cannot hold an `await` expression

**File:** `Sources/SpektraFilmFast/ManagedIngest.swift`
**Error:** `left side of nil coalescing operator '??' has non-optional type
'String', so the right side is never used` — and, once that was resolved,
`async call in an autoclosure that does not support concurrency`.

The original:

```swift
let sourceHash = expectedHash ?? (try await sha256(url: source))
```

The right-hand side of `??` is an `@autoclosure`, and autoclosures cannot be
`async`. This fails on any toolchain, not just Swift 6.

**Fix:** branch explicitly, hoisting the `await` out of the autoclosure:

```swift
let sourceHash: String
if let expectedHash { sourceHash = expectedHash } else { sourceHash = try await sha256(url: source) }
```

The rule: **`await` cannot live inside an autoclosure (`??`, `map`, `filter`,
`compactMap`, `assert`, and friends). Branch instead.**

## 5. `NSEvent` crossing an isolation boundary (non-Sendable)

**File:** `Sources/SpektraFilmFast/SpektraFilmFastApp.swift`

`addLocalMonitorForEvents` has a `NSEvent? -> NSEvent?` signature, but it is
invoked from a non-main thread while the body touched main-actor state. `NSEvent`
is not `Sendable`, so returning or passing it across the boundary is rejected
under Swift 6. The nested `applyRating` / `applyFlag` closures inside the
`MainActor.assumeIsolated` block also captured main-actor state without being
isolated themselves.

**Fix:** compute a `Bool` inside the isolated region and let the outer closure do
the non-isolated work, so `NSEvent` never crosses the boundary:

```swift
let handled: Bool = MainActor.assumeIsolated {
    guard let model else { return false }
    ...
    @MainActor func applyRating(_ value: Int) { ... }
    @MainActor func applyFlag(_ value: ProjectFlag) { ... }
    ...
    default: return false
}
return handled ? nil : event
```

Note every `return event` inside the isolated block became `return false` or
`return true`; the handler returns `nil` when it consumed the event.

The rule: **never return or pass a non-`Sendable` AppKit/Foundation object
through an isolation boundary. Return a `Bool` and convert outside.**

## 6. Mutated loop `var` captured by `@Sendable` closure

**File:** `Sources/SpektraFilmFast/AppModel.swift`

A `var job` is reassigned each iteration of a loop, and `job.settings` was read
inside a `Task.detached`. Capturing the mutable `var` in a `@Sendable` closure is
a data race and a Swift 6 error.

**Fix:** copy the needed values into `let` constants *before* the closure, then
capture only those:

```swift
let geometrySettings = item.look.geometry
let exportSettings = job.settings
let output = try await Task.detached(priority: .utility) {
    let geometryOutput = GeometryEngine.transformed(filmOutput, settings: geometrySettings)
    return try geometryOutput.resizedForExport(settings: exportSettings)
}.value
```

The rule: **a `@Sendable` closure may only capture immutable copies. Hoist
loop-mutated `var`s into `let`s first.**

## 7. Hard-clipping diagnostics were computed pre-conversion

**File:** `Sources/SpektraFilmFast/StudioAnalysis.swift`
**Found by:** `scripts/qa_production.py` pass 7.

This one was a genuine behavioural bug, not a toolchain issue. Clipping
indicators mixed two different buffers: `outputPeak`/`outputLuma` came from
`diagnosticBuffer` (final, display-referred pixels), but `isHardHighlight` and
`isHardShadow` were derived from `sourcePeak`, read from the linear `output`
buffer before display conversion. The hard-clip overlay therefore disagreed with
what the photographer actually saw.

The repo's own QA asserts the correct contract — hard clipping must be
final-output-only, and diagnostics must not inspect pre-film values. The source
violated it, so `verify_source.sh` failed before it ever reached compilation.

**Fix:** all four indicators now derive from the final output; the pre-conversion
`sourceR/G/B` reads were removed, along with the then-unused `x`, `y` and
`sourceIndex` bindings in that loop.

## 8. `SOURCE_MANIFEST.sha256` must be regenerated after any source edit

`verify_source.sh` compares a `find`-derived file list against the manifest and
then verifies every SHA-256. Any edit to a covered file fails the gate until the
manifest is regenerated — by design, so silent source drift is impossible. This
is also why problem 7 surfaced as a confusing "does not cover the complete
source package" message rather than as the analysis bug it really was.

Regenerate with:

```bash
find . -type f -not -path './.build/*' -not -path './dist/*' \
  -not -path './.git/*' -not -name 'SOURCE_MANIFEST.sha256' -print \
  | sed 's#^./##' | LC_ALL=C sort \
  | while IFS= read -r f; do shasum -a 256 "$f"; done > SOURCE_MANIFEST.sha256
```

`v0.6.0-swift6-fixes.patch` includes the updated manifest, so a normal builder
run needs no manual step.

## 9. QA script itself had drifted out of date (two assertions)

`scripts/qa_production.py` failed on its own pinned commit — the checks were
written against an older revision of the code.

- **Pass 7** asserted the literal `let outputPeak = max(outRRaw`, but the real
  expression is `let outputPeak = max(outR, max(outG, outB))`. Updated to the
  actual text. (The assertion's *intent* is preserved and is now genuinely
  enforced via problem 7.)
- **Vectorscope check** asserted a hardcoded `"123.0"` skin reference angle.
  The angle is now *derived* from a reference swatch in `SkinToneReference.swift`
  (it computes to 124.024°), and `ScopeEngine` correctly consumes the shared
  constant. Replaced with assertions that the shared derived constant exists and
  is used — which is the real contract and is stricter than the old literal check,
  since a hardcoded angle drifting from the swatch is exactly the bug that
  motivated the change.

## Verification performed

```bash
./BUILD_EXACT_GITHUB_V0.6.command
```

- `verify_source.sh` passed: whole-target type-check, manifest, shell syntax,
  resource hashes, and the full QA suite (warnings only, no errors).
- `swift build -c release` succeeded; native core built from the pinned commit.
- App bundle passes `codesign --verify --deep --strict` and is ad-hoc signed.
- Binary is Mach-O 64-bit `x86_64`, matching the Intel-only target.
- Launched successfully; process stays resident with no crash reports.

Known-harmless remaining warnings (from upstream, not touched): explicit
`self` capture suggestions in `AppModel.swift` task groups, and a `var job` in
`ManagedIngest.swift` that is never mutated.

## Build outputs

- App: `SpektraFilmFast-v0.6.0-pinned/dist/SpektraFilm.app`
- ZIP: `SpektraFilmFast-v0.6.0-pinned/dist/SpektraFilm-0.6.0-macOS-intel.zip`
- Log: `build.log`

## Do not do these

- Do not hand-edit `SpektraFilmFast-v0.6.0-pinned/` — the reset will erase it.
  Put the change in `v0.6.0-swift6-fixes.patch` and add any new path to
  `PATCHED_FILES` in the builder script.
- Do not generate patch files by redirecting `rtk` output.
- Do not skip `scripts/verify_source.sh`. It catches cross-file type errors that
  a single-file parse cannot, and it is what surfaced problem 7.
- Do not regenerate `SOURCE_MANIFEST.sha256` before understanding *why* the gate
  failed — a manifest error is often the visible symptom of a real source bug.

---

## Previous BUILD.md

# Build SpektraFilm v0.5 locally on macOS

You do not need a GitHub repository or GitHub Actions. `Resources/SpektraFilm.metallib` is already bundled.

## Requirements

- macOS with Xcode 26 / macOS 26 SDK
- Xcode Command Line Tools
- Internet access on the first build so the pinned native source can be fetched

## One-click build

1. Unzip this folder on the Mac.
2. Double-click `BUILD_ON_MAC.command`.
3. macOS may ask whether to open the command file; approve it.
4. When the build completes, Finder opens the `dist` folder.
5. Launch `SpektraFilmStudio.app`.

The build creates an Intel x86_64 application. Apple Silicon is intentionally not built for this release. The included `.metallib` is copied directly into the app bundle; the build does not recompile the Metal shader library.

## Optional production signing

By default the app is ad-hoc signed for local use. If you have a Developer ID identity, set `SPEKTRAFILM_CODESIGN_IDENTITY` before running `scripts/build_app.sh`, then use `scripts/notarize_app.sh` for notarization/stapling.


---

## Previous WORKFLOW.md

# Practical photo workflow in SpektraFilm Studio

## 1. Import with intent

Open **Library → Import Photos…**. Choose images, a shoot folder/camera card, a Lightroom Classic catalog, or a previously created iCloud library. Review the destination and backup choice before starting. A reference import indexes local originals without moving them; verified ingest intentionally creates a working copy and backup. If importing `.lrcat`, review the migration report for missing originals and unmapped settings before treating the transfer as finished.

**Do not put the only copy of a wedding or client session into an untested cloud migration.** Keep your original media, original Lightroom catalog, and an independent backup until you have checked multiple full-res renders and a second Mac.

## 2. Cull the session

Choose **Cull**. Start with **Analyze** to compute subject/facial sharpness, Apple Vision facial-capture quality and aesthetic-scoring models, highlight and shadow clipping, noise, possible blinks and similarity/burst candidates. Filter by characteristic using the toolbar's **Filter** menu. Use **Best Picks** to choose a folder or **All Folders**, and a suggested keep percentage (e.g., 25%). It will analyze missing files, select strong non-redundant frames, and mark them as picked. It **never deletes originals** or overrides a manual reject. Compare visually before delivery; metrics do not understand every creative intention.

## 3. Organize people

In **Library**, select **People → Rescan** to group faces found in photos. The engine checks multiple crops and may consolidate separate clusters when multiple photo examples agree. People detection is an organizational suggestion, not personal identity verification. When one person still appears in two groups, right-click one of them and choose **Merge Into Person…** to correct it. In mixed group pictures, use extra care: two people can appear together and should not be merged based on hairstyle/clothing.

## 4. Build a film look

Start **Edit** with **Adjust → RAW / White Balance**. Choose **As Shot** or **Auto**, or a customized preset that offsets the selected image's own WB. Set Apple RAW exposure, RAW Global Tone and recovery/headroom without clipping important information. This is technically distinct from **Film → Exposure EV** and **Film → Auto Exposure**: those controls act at the film stage.

Then move into **Film**. Choose a film stock and print-paper response. Work through the controls from the original [spektrafilm](https://github.com/andreavolpato/spektrafilm) logic: virtual negative characteristics, film exposure/development and density, printing/enlarger/paper, and scan behavior. Use the original stock and print controls to shape palette and tonality instead of looking for an independent generic color-grading page.

The **ME deSatch** Color Density group supports controlled `0 → -1` reductions in global or six hue sectors. If a look feels too heavy, use stock exposure/print and scene-white-balance adjustments before reaching for arbitrary saturation.

Select **Masks** for a subject/background/skin or a geometric mask. When a mask is selected, compatible adjustments target that mask until **Main Image** is chosen again. Use the common mask overlay to verify you're changing the intended region. Use **Lens Character** for optional optical falloff; drag the on-image center to line it up with the portrait composition.

Check **False Color, clipping warnings, histogram/waveform/vectorscope, and skin diagnostics**. Some monitors are proxies while dragging; verify the settled frame. Diagnostics are not a substitute for a 100% zoom check.

## 5. Deliver or retouch in Photoshop

For a quick individual image, right-click the Edit filmstrip photo or use the **Export** button, and set quality, destination, crop and resize in its compact dialog. For batch delivery, go to **Export**, check the queue, fit/crop, metadata, color space and filename pattern, and render the selected photos.

**My portrait workflow:** use SpektraFilm for the film base, export a full-resolution high-quality TIFF (16-bit when available), open that file in Adobe Photoshop, and do detailed portrait retouching there—skin cleanup, stray hair, distractions and any final pixel-level finishing. Save/deliver from Photoshop. This app does not ship Photoshop or automate its licensing.

## When renders feel slow

- Keep **interactive/idle preview** smaller while adjusting; let the exact settled frame finish.
- For diagnosis, export one picture without costly denoise/masks/halation/optical effects, then enable them individually to find the heavy stage.
- Check RAM and free disk/cache space before large Intel Mac batch exports.
- A full spectral/photographic negative → print → scan path is materially more work than one baked look-up. There *can* be internal spectral-reconstruction LUTs; it is **not** accurate to claim the entire application is LUT-free.
- A crash, export image mismatch or mysteriously frozen slider is a bug: preserve the diagnostic logs/RAW file and report it rather than rationalizing it as film fidelity.


---

## Previous RELEASING.md

# Releasing SpektraFilm

How to publish a pre-built app so users don't have to build it themselves.
The full checklist lives in `DEVELOPMENT_HISTORY.md` §9a; this file is the reference.

## Why publish a zip

The local build produces an **ad-hoc signed, un-notarized** app. Anyone who
clones and runs `BUILD_ON_MAC.command` also needs macOS 26 / Xcode 26 and ~10
minutes. Publishing the zip removes both barriers — they just download and drag.

The cost is one honest paragraph in the release notes telling people how to clear
Gatekeeper once. That is cheaper than making everyone install Xcode.

## Before you build

Bump `VERSION` in the repo root. The build stamps the version into
`Info.plist`, the zip filename, and `build-info.txt`, and the source gate
rejects a malformed `VERSION`.

Build from a clean tree on `main`, so the artifact matches the commit you tag:

```bash
git checkout main && git pull --ff-only
git status --porcelain      # must be empty
```

## 1. Build

```bash
SPEKTRAFILM_CLEAN=1 ./BUILD_ON_MAC.command
```

`SPEKTRAFILM_CLEAN=1` matters: it forces a from-scratch build and writes
`incremental_build=no` into `dist/build-info.txt`. An incremental build
(`incremental_build=yes`) is fine for your own testing but must not be published —
it can carry stale object files, so two people building the same commit can get
different bytes.

> The build needs only macOS + Xcode 26. No network, no Python.

## 2. Verify before publishing

```bash
codesign --verify --deep --strict dist/SpektraFilm.app   # must pass
lipo -archs dist/SpektraFilm.app/Contents/MacOS/SpektraFilm   # x86_64
grep -E 'version|incremental_build|codesign_identity' dist/build-info.txt
unzip -t dist/SpektraFilm-*.zip                          # "No errors detected"
```

Then confirm the zip restores a working app:

```bash
mkdir -p /tmp/vfy && unzip -q dist/SpektraFilm-*.zip -d /tmp/vfy
codesign --verify --deep --strict /tmp/vfy/SpektraFilm.app
lipo -archs /tmp/vfy/SpektraFilm.app/Contents/MacOS/SpektraFilm
rm -rf /tmp/vfy
```

Check the same things `DEVELOPMENT_HISTORY.md` §9 asks for. Note that
"notarization and Gatekeeper assessment succeed" **cannot** pass for a local
build — see the limitation below.

## 3. Write the notes

Start from the existing release notes and update the version, the commit, and the
build number. This block is the part users actually need:

````markdown
### Install

1. Unzip `SpektraFilm-<VERSION>-macOS-intel.zip`.
2. Drag `SpektraFilm.app` into your **Applications** folder.
3. Launch it.

### If macOS blocks it on first open

This build is **ad-hoc signed and not notarized**, so Gatekeeper will show:

> "SpektraFilm" cannot be opened because the developer cannot be verified

That is expected — it is not a corrupt download. Clear it once:

**Option A — right-click → Open**: right-click the app in Applications, choose
**Open**, then **Open** again in the dialog.

**Option B — from Terminal:**
```
xattr -dr com.apple.quarantine /Applications/SpektraFilm.app
```

You only do this once per Mac.

### Requirements

- macOS 15.0 or newer
- Intel; on Apple Silicon run `softwareupdate --install-rosetta` first
- No other dependencies, no network needed
```

Always keep two honest notes in there:

- **Presets are per-Mac.** Settings live in
  `~/Library/Application Support/SpektraFilm/presets.json`, not inside the app, so
  they do not travel with the download.
- **It is unsigned.** Unsigned apps cannot be distributed through the Mac App Store.
````

## 4. Publish

```bash
git rev-parse --short HEAD     # record this
gh release create v<VERSION> \
  dist/SpektraFilm-<VERSION>-macOS-intel.zip dist/SHA256SUMS.txt \
  --target main \
  --title "SpektraFilm <VERSION> — Intel (x86_64) macOS app" \
  --notes-file RELEASE_NOTES.md
```

`--target main` is required; a raw commit SHA is rejected by the API
(`target_commitish is invalid`).

Never re-point or overwrite a published tag. Ship a new version instead.

## 5. Verify what you published

```bash
gh release download v<VERSION> --pattern '*.zip' --dir /tmp/relcheck
shasum -a 256 /tmp/relcheck/*.zip dist/SpektraFilm-<VERSION>-macOS-intel.zip
```

The two hashes must match. This catches a truncated or stale upload — it has
already happened once in this project's history (a stale artifact hash).

Also confirm the tag lands on the built commit:

```bash
git fetch --tags origin
git rev-parse v<VERSION>^{commit}   # must equal git rev-parse origin/main
```

## Notarization (removes the Gatekeeper warning)

Everything above publishes an app that works but shows a Gatekeeper warning.
`scripts/notarize.sh` does the whole job. It will not run until you supply an
Apple Developer account — that part is genuinely not automatable.

```bash
./scripts/notarize.sh --check     # report what's missing; changes nothing
./scripts/notarize.sh --run       # sign → submit → staple → verify → re-zip
```

`--check` is safe to run any time and is the fastest way to see what's left.

### One-time setup

1. **Enrol** in the [Apple Developer Program](https://developer.apple.com/programs/enroll/)
   ($99/yr). Individual or Organisation both work.
2. **Create a Developer ID Application certificate.**
   Xcode → Settings → Accounts → Manage Certificates → *+* → **Developer ID**.
   Or import an existing `.p12`:
   ```
   security import cert.p12 -k ~/Library/Keychains/login.keychain-db
   ```
3. **Store notary credentials.** These are never written into the repo:
   ```
   xcrun notarytool store-credentials spektra --apple-id you@example.com --team-id TEAMID
   export NOTARY_PROFILE=spektra
   ```
   For CI, use an App Store Connect API key instead:
   ```
   export NOTARY_KEY_ID=... NOTARY_ISSUER_ID=... NOTARY_KEY_PATH=/path/AuthKey_xxx.p8
   ```

Then `./scripts/notarize.sh --check` should be clean, and `--run` publishes a
zip that opens with no warning and no `xattr` step.

### What the script does

Signs with `--options runtime --timestamp` (both required for notarization),
submits with `--wait`, staples, checks `spctl` reports *notarized*, then rebuilds
the zip and `SHA256SUMS.txt` from the stapled bundle.

Two details it handles that are easy to get wrong by hand:

- **`notarytool` will not accept a bare `.app`** — only `.zip`/`.dmg`/`.pkg`. The
  script zips for submission, then rebuilds the distributable zip *after*
  stapling. Submit the pre-staple zip and your published copy stays unstapled.
- **`--timestamp` is mandatory** for Developer ID. Without it the signature is
  not valid for notarization, and there is no error at signing time.

### Why no entitlements

`scripts/SpektraFilm.entitlements` is an intentionally **empty** plist. The
hardened runtime only requires entitlements for capabilities that gate code
execution or sandbox access, and the app uses none: no `dlopen`, no JIT, no
plugins (the `NSBundle` calls look up the bundled `.metallib`, they do not load
code), not sandboxed, single binary. The reasoning is recorded in that file —
add to it if a future change introduces plugin loading, JIT, or a helper binary.

### Don't trust `spctl` locally

With Gatekeeper assessments disabled, `spctl -a` prints `accepted` with
`override=security disabled` and has **not assessed anything**. Check
`spctl --status` before believing a local pass. The script warns when it sees
this; confirm the result on a clean Mac or with assessments enabled.

### Once notarized

Drop the "if macOS blocks it" block and the `xattr` command from the release
notes, and update `DEVELOPMENT_HISTORY.md` §9 — "notarization, stapling, and Gatekeeper
assessment succeed" becomes checkable rather than aspirational.