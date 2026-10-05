# SpektraFilmFast 0.5.3 — Studio Workflow

SpektraFilmFast is a non-destructive macOS still-photo studio built around the Spektrafilm native Metal renderer. It combines Library, Cull, client Proofs, film-oriented editing, professional scopes, crop/geometry, and delivery/export in one application.

> **Vibe-coded disclosure:** this project was vibe-coded end-to-end. Product direction, architecture, implementation, debugging, UI iteration, QA scaffolding, and documentation were developed interactively with AI assistance under human direction and testing. The source is intentionally public so every shortcut, influence, limitation, and attribution can be inspected and improved.

**Support SpektraFilmFast:** [Buy Me a Coffee — kbvisualz](https://www.buymeacoffee.com/kbvisualz)

## Repository description

Use this as the public GitHub description:

> Open-source, vibe-coded macOS photo studio built around Spektrafilm: Library, Cull, ProofDock client proofing, film editing, scopes, crop/geometry, and export. Built in the open and welcoming improvements, experiments, and new features.

## What is included

### Library and Cull

- folder or file import with asynchronous metadata/thumbnail warmup;
- search, sort, folder filters, albums, saved smart collections, ratings, flags, color labels, and export queue state;
- multi-selection-aware keyboard shortcuts and right-click batch actions;
- XMP sidecar read/write with optional automatic decision writes;
- local Smart Cull analysis, compare/survey/loupe views, explainable scores, face/focus/exposure checks, and persistent analysis cache;
- local **People / Face Groups** that cluster repeated faces on-device and expose them as Library filters; no face data is uploaded;
- corrected orientation-aware thumbnails and schema invalidation for old upside-down previews.

### Proofs

ProofDock is integrated as a first-class workspace rather than an external detour:

- generate client proofs from selected/cull results;
- short `/g/<code>` client links, cover image, Open Graph preview, optional password and selection limit;
- no client login;
- heart-only selection, click-to-fullscreen, Finish Selection locking, and link regeneration while preserving picks;
- sync client selections back into Library as **Client Picks**.

### Edit

- all existing Spektrafilm Film / Print / DIR / Grain / Halation / Diffusion / Scanner controls remain available;
- White Balance: As Shot, Auto, Custom, always-visible Temperature/Tint, relative per-image technical presets, and relative creative presets such as Golden Hour, Sunset, Sunrise, Blue Hour, Candlelight, Moonlight, Open Shade, and more;
- Tone: Exposure, Brightness, Contrast, Midtones, Highlights, Shadows, Highlight Recovery, Shadow Recovery, Whites, Blacks, White Point, Black Point, plus point curves;
- Tone Curve preset groups: Technical, Film Response, and Creative;
- Color Density: master and RGB/CMY density controls with luminance-preserving behavior;
- Crop & Geometry: live viewer crop frame, crop/media/cinema presets, IMAX ratios, straighten, Auto/Level/Vertical/Full/Guided-style geometry, offsets, flips, guides, and Auto Fill zoom to avoid black edges;
- individual slider reset, Reset Section, **Reset All Edits**, beginner-language hover tooltips, Undo/Redo, Copy/Paste Look;
- preset rail can be hidden and the choice is remembered.

### Scopes and diagnostics

Scopes remain available while editing: Histogram, Waveform, RGB Parade, Vectorscope, Skin Vectorscope, and CIE Chromaticity.

Exposure Warning and skin diagnostics analyze the **final rendered image**, not the RAW-side source. The intended ordering is:

`RAW develop → WB → host tone/curve/density → Spektrafilm stock/print processing → crop/geometry → final rendered buffer → Exposure/Skin diagnostics → viewer presentation`

That means changing film stock, print, contrast, curves, density, or geometry changes the warning/skin result too.

The skin system combines on-device Apple Vision subject isolation with published open-source skin-color heuristics. The overlay and Skin Vectorscope share one confidence-weighted skin measurement and report **Too Green / On Target / Too Magenta**. The scope shows both the measured centroid and its target on the skin line.

## Working-file / preview architecture

The original RAW/JPEG remains immutable. Editing uses one fixed **1080 px long-edge linear workfile** rather than reopening/redeveloping the source on every adjustment:

1. Decode/develop the source once into the cached 1080 px linear working file.
2. Keep the selected photo hot and prewarm nearby photos so next/previous navigation avoids repeated RAW development.
3. Live slider/crop interaction and the idle edit preview both stay at **1080 px**; there is no automatic 1800/2K refinement after you stop dragging.
4. Latest-request-wins scheduling discards stale slider positions instead of building a render backlog.
5. **Full Resolution Preview** and **Export** are the only paths that return to the original source and apply the saved recipe at source resolution.

The Spektrafilm renderer already supports no-copy shared Metal buffers for contiguous image memory. The remaining performance opportunity is a fully Metal-backed viewer surface that removes the CPU float-buffer → `CGImage` display handoff; this source does not falsely claim that final display-copy elimination is complete.

## Export presets

Built-in export presets include:

- **High Quality** — RapidRAW reference default: JPEG 95, full size, metadata retained.
- **Fast Web** — RapidRAW reference default: JPEG 80, 2048 px width, don't enlarge, delivery-safe metadata/GPS behavior.
- **Social Media** — Instagram Square (1080×1080), Instagram Portrait (1080×1350), Story/Reel/TikTok (1080×1920), LinkedIn Square (1200×1200), LinkedIn Landscape (1200×627), X Landscape (1600×900), YouTube Thumbnail (1280×720).

Social presets fit inside the target dimensions without silently changing the crop. When the image crop already matches the destination aspect ratio, the output lands on the exact preset dimensions.

## Renderer contract

The native film renderer remains pinned to Spektrafilm core commit:

`8f6651858f439a99b7202b4b8dea59e344dadf5d`

`Resources/SpektraFilm.metallib` is precompiled and included. Do not silently substitute another renderer or unpin the native core without parity/performance validation.

## Open-source credits and support links

SpektraFilmFast is deliberately transparent about the projects that informed it. `IMPLEMENTATION_SOURCES.md` records exactly what was studied and how it was used.

| Project | What informed SpektraFilmFast | Upstream | Support / donation discovered in upstream repo |
|---|---|---|---|
| Spektrafilm OFX | Native film/print/scan renderer and bridge | [GitHub](https://github.com/chaert-s/spektrafilm-ofx) | No funding URL advertised in the repository at audit time |
| RapidRAW | Preview-worker/backpressure patterns, cache strategy, export defaults, and tone/recovery behavior references | [GitHub](https://github.com/CyberTimon/RapidRAW) | [Ko-fi — cybertimon](https://ko-fi.com/cybertimon) |
| Alcedo Studio | Exposure/ACEScc behavior, curve interaction, tone-panel organization, scope presentation | [GitHub](https://github.com/zidage/AlcedoStudio) | [Upstream support/discussion link](https://github.com/zidage/AlcedoStudio/discussions/44) |
| darktable | Published curve preset nodes and crop/perspective workflow references | [GitHub](https://github.com/darktable-org/darktable) | No repository funding URL discovered |
| RawTherapee | RAW/editor workflow and clipping behavior reference | [GitHub](https://github.com/Beep6581/RawTherapee) | No repository funding URL discovered |
| Primera Suite | Density behavior and rg-chromaticity skin classification reference | [GitHub](https://github.com/geoffsmithBK/primera-suite) | No repository funding URL discovered |
| Vectorscope Skin Tone Analyzer | YCbCr/HSV skin ranges and deviation concepts | [GitHub](https://github.com/DeoTime/vectorscope) | No repository funding URL discovered |
| OpenPost | Published social-media output dimensions | [GitHub](https://github.com/getopenpost/openpost) | No repository funding URL discovered |
| filmr | Film H-D curve/toe/shoulder concepts used to inform film-response curve recipes | [GitHub](https://github.com/W-Mai/filmr) | No repository funding URL discovered |

Apple Vision, Core Image, Accelerate/vImage, Metal, SwiftUI, AppKit, and ImageIO are Apple platform technologies rather than open-source references.

## Contributing

This project is meant to be improved in public. Contributions are welcome for bug fixes, performance work, UI refinement, additional camera workflows, better diagnostics, new curve/WB/export recipes, new scopes, retouch tools, masking, smarter culling, proofing improvements, and ideas that have not been tried yet.

If you have a better algorithm or architecture, show the source and measurements. If a feature comes from or is inspired by another project, preserve the attribution and license information rather than hiding it. Additions should remain non-destructive and should not remove existing features just to simplify the UI.

## Local Mac build

No GitHub Actions workflow is required for a release. A Mac is still required to compile the Swift/AppKit/Objective-C++ application executable.

Double-click `BUILD_ON_MAC.command` on a Mac with Xcode 26 / the macOS 26 SDK. The local build creates an Intel x86_64 app and:

- `dist/SpektraFilm-0.6.0-macOS-intel.zip`
- `dist/SHA256SUMS.txt`
- `dist/build-info.txt`

The bundled `.metallib` means the Metal shader library itself does not need to be rebuilt. The current native bootstrap may fetch the pinned public Spektrafilm source the first time the Objective-C++ bridge/static library is compiled; this requires no GitHub account and subsequent builds reuse the local cache.

A public release still requires Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper assessment, `--self-test`, and `--studio-soak-test` as documented in `PRODUCTION_QA.md`.

### Toolchain support (Swift 6.2 / Xcode 26)

v0.6.1 and later build cleanly on **Swift 6.2 / Xcode 26**. v0.6.0 as originally
tagged does not — it was authored against an older toolchain and fails to compile.
Five defects were fixed and each is now asserted by `scripts/verify_source.sh`, so
a regression fails the source gate instead of the build:

| Trap | Rule |
|---|---|
| `async func` does not inherit `@MainActor` inside `Task {}` | annotate `@MainActor` explicitly |
| `await` cannot live in an autoclosure (`??`, `map`, `filter`) | branch with `if let` |
| `NSEvent` is not `Sendable` | return a `Bool` inside the isolated region, convert outside |
| `@Sendable` closures cannot capture a loop-mutated `var` | hoist `let` copies first |
| hard-clip diagnostics must read the **final** output buffer | never use pre-conversion values |

`.github/workflows/ci.yml` runs the whole source gate on every push, including a
real `swiftc -typecheck` of all sources, so these are caught in CI rather than on
someone's machine. See `AI_PITFALLS.md` §10–18 for the full symptom/cause/fix
write-ups, and `AI_HANDOFF.md` for the build contract.

Two things to know before editing anything:

- **Any source edit requires regenerating `SOURCE_MANIFEST.sha256`.** A manifest
  error is often a symptom of a real bug, not the bug itself.
- **Never hand-edit a checkout that a build wrapper resets to a pinned commit** —
  put the change in a commit, or the next build erases it.

## License

GPLv3 for SpektraFilmFast/Spektrafilm portions unless a third-party notice states additional terms. See `LICENSE`, `NOTICE.md`, and `IMPLEMENTATION_SOURCES.md`. Open-source reference projects retain their own licenses and copyrights.
