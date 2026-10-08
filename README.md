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
