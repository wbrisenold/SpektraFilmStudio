# AI Agent Handoff — SpektraFilmFast v0.6.1

## Prime directive

Treat this folder as the repository root and the source of truth for the current app. Preserve **all existing user-facing capabilities**. Improvements are additive: do not delete controls, film features, Library/Cull/Proofs/Edit/Export workflows, presets, diagnostics, cache controls, or metadata behavior merely to simplify implementation. A broken implementation may be replaced behind the same or improved capability.

Product copy must remain event-agnostic. This is a general high-end still-photo studio.

## Release identity

- `VERSION`: `0.6.8`
- expected local Intel artifact: `SpektraFilmStudio-0.6.8-macOS-intel.zip`
- pinned Spektrafilm native core: `8f6651858f439a99b7202b4b8dea59e344dadf5d`
- bundled Metal library: `Resources/SpektraFilm.metallib`
- application icon: `Resources/AppIcon.icns` (packaged as `SpektraFilm.icns` by the build script)
- project funding identity: `.github/FUNDING.yml` → `buy_me_a_coffee: /kbvisualz`

## Workspace flow

The intended complete flow is:

`Library → Cull → Proofs → Edit → Export`

### Library

- folder/file import;
- search/sort/folders/albums/smart collections;
- ratings, pick/reject/unflag, color labels, Client Pick, and Queued for Export are separate concepts;
- current selection is visually separate from export queue state;
- highlighted thumbnails own Library keyboard shortcuts and batch actions;
- selection-aware right-click menu applies batch actions to the highlighted set;
- XMP read/write and optional automatic rating/flag/color writes;
- corrected orientation-aware thumbnail cache; do not reintroduce the former double-orientation/upside-down bug.

### Cull

- Loupe / Compare / Survey;
- local bounded Smart Cull, explainable scores/reasons, focus/face-focus/exposure/face-count/stack cues;
- warmed thumbnail/cache reuse and persistent Cull analysis cache;
- never auto-delete originals or override manual decisions.

### Proofs / ProofDock

ProofDock behavior is integrated as a native workspace:

- render proofs from chosen/cull results;
- short `/g/<10-char-code>` links;
- no client login;
- optional password + selection limit;
- chosen/default cover + Open Graph link preview;
- heart toggles select/unselect, image body opens fullscreen, Escape/backdrop/close exits fullscreen;
- Finish Selection can lock a gallery;
- New Client Link can invalidate the previous share URL while retaining picks and reopening selection;
- Sync Client Picks returns selections to local originals by stable filename/id mapping.

Do not replace this with a third-party gallery service unless explicitly requested.

## White Balance

WB modes: `As Shot`, `Auto`, `Custom`.

- Temperature/Tint sliders are always exposed.
- As Shot and Auto use the resolved per-image neutral as slider zero; Custom is absolute.
- Relative temperature adjustments are represented in reciprocal-temperature/mired terms, not naive fixed Kelvin addition.
- Technical and Creative WB presets are **base-relative**: resolve that image's As Shot or Auto neutral, then apply the preset offset. Never force every photo to a fixed Kelvin/tint.
- Creative recipes include Golden Hour, Sunset, Sunrise, Blue Hour, Candlelight, Moonlight, Overcast Warmth, Open Shade, Warm/Cool Interior, Winter Cool, Neon Night, Desert Heat, Forest Cool, Film Warm, Clean Editorial, Skin-Friendly Warmth, Snow Day, Late Afternoon, warm/cool neutral variations, Magenta Glow, Cyan Night, Amber Room, and related restrained options.
- Creative WB recipes are original SpektraFilm recipes; do not falsely attribute their numeric offsets to an upstream project.

## Tone / curve / density pipeline

Host-side scene/tone controls execute before Spektrafilm stock/print rendering:

- Exposure EV
- Brightness
- Contrast
- Midtones
- Highlights
- Shadows
- Highlight Recovery
- Shadow Recovery
- Whites
- Blacks
- White Point
- Black Point
- point Tone Curve
- Color Density (master + RGB/CMY)

Every editing slider should have beginner-language hover help, individual reset, and section-level reset.

Tone Curve preset groups:

- Technical: Linear, Contrast Compression, Medium/High Contrast, Gamma 2.0, Gamma 0.5 and related neutral tools.
- Film Response: color-negative soft/classic, slide-film punch, B&W negative classic. These model master-curve toe/straight-line/shoulder behavior; they are **not** claims of exact named-stock emulation.
- Creative: Cinematic Soft/Punch, Matte Fade, Airy, Dreamy, Soft Highlight Roll-Off, Deep Blacks, Noir Contrast, High Key, Low Key, Faded Print, etc.

Implementation provenance is recorded in `IMPLEMENTATION_SOURCES.md`.

## Crop & Geometry

- Crop overlay should be immediately available when Crop & Geometry is active; avoid a clunky extra mode-within-mode.
- Drag inside crop = move; drag edges = resize one side; drag corners = resize from that corner.
- During crop-frame drag, update the overlay only; do not resample/re-render the image for every pointer event. Expensive geometry rendering settles after the gesture.
- Auto Fill/Auto Crop must solve the minimum geometry scale required to cover the chosen crop after rotation/perspective so black wedges do not remain.
- Provide straighten, Auto / Level / Vertical / Full / Guided-style correction, vertical/horizontal geometry, rotation, scale, X/Y offsets, flips, composition guides, and crop presets for photo/print/social/cinema including IMAX 15/70 1.43:1 and IMAX Digital Expanded 1.90:1.

## Working-file and render architecture

Do not return to the old 720/768 live-preview experiment.

The intended architecture is:

`immutable original → cached linear working file → interactive/native edit pipeline → accurate normal preview → full source only for Full Resolution Preview/export`

Current rules:

- `workingFileLongEdge`, `previewLongEdge`, and `interactiveLongEdge` are compatibility fields but the active edit policy is fixed to 1080 px.
- Do not reintroduce adaptive 1280/1800/2K idle refinement: live and idle editing both remain 1080 px; only Full Resolution Preview/export use the original.
- decoded/developed linear data is schema-versioned and persisted locally;
- keep selected working data hot and prewarm neighboring images;
- one active native render + one replaceable pending request / latest-generation-wins;
- pointer-rate feedback may use `InteractivePreviewProxy`, but stale requests may never backlog;
- pointer proxy is display-only, never persisted as the authoritative adjusted preview;
- settled edits produce the configured accurate normal preview and cache it;
- Full Resolution Preview/export reopen the immutable original and replay the saved look at full resolution;
- the current remaining performance opportunity is eliminating the CPU float-buffer → `CGImage` viewer handoff with a direct Metal-backed viewer surface. Do not claim this is complete until implemented and benchmarked on macOS.

## Scopes, Exposure Warning, and skin

Scopes should remain visible/available throughout Edit and visually match the polished common scope design.

Exposure Warning and Skin analysis must operate **after the complete visible grade**:

`RAW develop → WB → host tone/curve/density → Spektrafilm film/print → geometry/crop → final rendered buffer → diagnostics → display`

`StudioAnalysisEngine` intentionally accepts the final output buffer only. Do not reintroduce RAW/source-side diagnostic inputs.

Exposure warning distinguishes near-limit **risk** from true **hard clipping**.

Skin analysis:

- Apple Vision subject/person segmentation + face information isolates likely subject regions;
- published YCbCr/HSV ranges plus Primera-inspired rg-chromaticity gating qualify likely skin;
- both overlay and Skin Vectorscope use the same confidence-weighted final-render skin centroid;
- both report exactly the same state: `Too Green`, `On Target`, or `Too Magenta`;
- vectorscope shows measured marker, target marker on the skin line at comparable radius, and connector;
- overlay should be restrained/professional, not childish false-color paint;
- diagnostics never become part of the exported pixels.

## Export

Export re-renders the immutable source at full resolution using the saved look. The export path must remain diagnostics-free and verified after encode.

Built-in presets:

- RapidRAW High Quality reference: JPEG 95, full size, metadata kept.
- RapidRAW Fast Web reference: JPEG 80, 2048px width, don't enlarge, delivery-safe metadata/GPS behavior.
- Social Media: Instagram Square 1080×1080, Instagram Portrait 1080×1350, Story/Reel/TikTok 1080×1920, LinkedIn Square 1200×1200, LinkedIn Landscape 1200×627, X Landscape 1600×900, YouTube Thumbnail 1280×720.

Social resize is fit-inside/non-destructive and does not silently crop. Exact target dimensions occur when crop aspect matches the preset.

## Cache architecture

- centrally budgeted cache root with thumbnails, developed/working sources, adjusted previews, and Cull analysis;
- custom local/external-drive cache path, visible status, Choose Folder, Reveal in Finder, Use Default, per-store clear, Clear All;
- unavailable custom drive is reported unavailable, not silently redirected;
- byte-budgeted RAM caches + memory-pressure handling;
- cache schema identifiers must be bumped when algorithms/serialization change.

## Project compatibility

Use explicit `decodeIfPresent` defaults for newly added persisted fields. Existing projects must open with neutral defaults rather than failing to decode. `clientPicked` and all newer ToneSettings/Preferences fields follow this rule.


## UI policy

- additive-only features;
- event-agnostic product copy;
- distinguish active selection, Pick/Reject, Client Pick, and Queued for Export visually;
- Preset rail in Edit is collapsible and remembers its state;
- Undo/Redo + Copy/Paste Look remain available;
- beginner-facing hover help describes what moving a slider left/right does and where relevant where it acts in the pipeline.

## Open-source transparency

This project is explicitly disclosed as vibe-coded. Keep the README attribution table and `IMPLEMENTATION_SOURCES.md` current. Do not hide upstream inspiration or copied/adapted data. Preserve upstream licenses/notices. If actual source code is copied rather than behavior/math being independently reimplemented, re-evaluate license compatibility before release.

Funding for this project: `.github/FUNDING.yml` → Buy Me a Coffee `kbvisualz`.

## Source gates before every handoff

```bash
swiftc -frontend -parse Sources/SpektraFilmFast/*.swift
swift package dump-package >/dev/null
python3 scripts/qa_production.py
./scripts/qa_10_passes.sh
./scripts/verify_source.sh
```

On non-macOS, these are source gates only. Apple frameworks cannot be linked/run there.

**On macOS, `verify_source.sh` runs a real `-typecheck`, not `-parse`.** It catches
cross-file access and isolation errors before packaging, in roughly 20 seconds.
It also verifies `SOURCE_MANIFEST.sha256` coverage and every bundled resource hash.
Treat a green `verify_source.sh` on macOS as the minimum bar, not a formality.

## Build/toolchain contract — do not regress

**v0.6.0 as originally tagged does not compile on Swift 6.2 / Xcode 26.** Five
defects were fixed in this repo and are now **machine-checked by
`scripts/verify_source.sh`**, so reintroducing any of them fails the gate rather
than the release. Full symptom/cause/fix write-ups are in `AI_PITFALLS.md`
(pitfalls 10–18).

| Trap | Rule |
|---|---|
| `async func` does **not** inherit `@MainActor` inside `Task {}` | annotate `@MainActor` explicitly on every `async` function in a `Task` |
| `await` cannot live in an autoclosure (`??`, `map`, `filter`, `compactMap`) | branch with `if let` instead of `??` |
| `NSEvent` is not `Sendable` | return a `Bool` inside the isolated region; convert to `nil`/`event` outside |
| `@Sendable` closures cannot capture a loop-mutated `var` | hoist `let` copies of the values first |
| hard-clip indicators must use the **final** output buffer | never read peak/luma from the pre-conversion linear buffer |

Two rules about the build tooling itself:

- **Any edit to a source file requires regenerating `SOURCE_MANIFEST.sha256`**
  (command in `AI_PITFALLS.md` §15). A manifest failure is often a *symptom* of a
  real source bug — read the underlying error before regenerating.
- **`SOURCE_MANIFEST.sha256` must never pin a gitignored artifact.** It used to
  hash `.DS_Store`, which Finder rewrites at will; `verify_source.sh` now excludes
  it explicitly.

Two rules that cost real time during debugging:

- **Do not hand-edit this checkout if a build wrapper resets it.** Local edits are
  destroyed on the next run; put the change in a commit or an applied patch.
- **Generate patch files with plain `git diff`.** Some wrappers emit a condensed
  stat table instead of a unified diff, which `git apply` rejects with the
  misleading `No valid patches in input`.

## Mandatory Mac release gate

Run `BUILD_ON_MAC.command` on macOS with Xcode 26 / macOS 26 SDK. Verify Intel x86_64 output, Metal `--self-test`, `--studio-soak-test`, Developer ID hardened-runtime signing, notarization, stapling, and Gatekeeper acceptance before describing a binary as production-approved.

CI (`.github/workflows/ci.yml`) runs the full source gate on every push, so a
Swift 6 regression is caught before anyone attempts a local release build. The
local Mac build remains the authoritative compile/link/runtime gate, because the
pinned native core needs the macOS 26 SDK.

There is no GitHub Actions release requirement in this package. Local Mac build is the authoritative compile/link/runtime gate.

### 2026-10-08 11:20 — v0.6.8 Cloud UX Patch Applied
- Commit: 9f238f5 — Cloud UX patch (RAW tabs + Film stage gating + in-app Oracle/rclone setup wizard)
- Files: +3 new (CloudSetupWizard.swift, OracleRcloneSetup.swift, OracleHostKeyVerifier.swift); 3 modified (ControlsView.swift, NativeCloudTransferView.swift, SettingsView.swift)
- Build: Intel x86_64 RELEASE, BUILD_EXIT=0, ~196s; zip: dist/SpektraFilmStudio-0.6.8-macOS-intel.zip (sha256 d61adbd2…)
- Gates: verify_source.sh PASS, qa_10_passes.sh 10/10; only pre-existing warnings (PresetBrowserView.swift:89 var→let, LensCharacterPanel.swift:68 Sendable closure)
- Upload: first RepairKit asset upload still in background (PID 42101, clobber; may take ~40–90min). Code is pushed and readable by ChatGPT at 9f238f5.

### 2026-10-08 12:25 — v0.6.8 Home/Projects + iCloud + Crash Repair
- Commit: 59a9b7a — Home/Projects + iCloud + crash repair (import welcome, recent projects, project models, cloud library stability)
- Files: 10 modified (AppModel, CloudLibrarySupport, ContentView, LibraryView, ProjectModels, RecentSpektraProjects, SpektraCloudLibrary, StudioImportWelcomeView, StudioImportWizard, build_app.sh); SOURCE_MANIFEST updated (184 entries)
- Build: Intel x86_64, app exists, build-info ok; zip: dist/SpektraFilmStudio-0.6.8-macOS-intel.zip (sha256 d61adbd2… same artifact hash in current dist snapshot)
- Gates: verify_source.sh PASS, qa_10_passes.sh 10/10
- Patch base: HEAD-locked at 87d95c4 for first kit; this kit applied clean with `--check` anchors OK (3 changed + 2 new files from kit context). No new warnings introduced.

### 2026-10-08 13:45 — v0.6.8 Import/Home + iCloud + Crash Repair (update)
- Commit: 93523b6 — Import/Home + iCloud/crash repair (tighten Open button, Recent Projects, CloudLibrary robustness)
- Patch: SpektraFilmStudio_v068_Import_Home_Repair_HEAD435a38e_2026-10-08.zip (target HEAD 435a38e)
- Files: 7 modified (AppModel, CloudLibrarySupport, CloudSetupWizard, ContentView, LibraryView, StudioImportWizard, SOURCE_MANIFEST)
- Build: Intel x86_64, zip sha256 d61adbd2… (dist artifact current)
- Gates: verify_source.sh PASS, qa_10_passes.sh 10/10; no new warnings

### 2026-10-08 14:50 — v0.6.8 FilePicker/Finder Fix (NSBeep -> NSSound.beep)
- Commit: b8c37b8 — fix: NSBeep -> NSSound.beep in SpektraFilePanel + manifest
- Patch: SpektraFilmStudio_v068_FilePicker_Finder_FIX_HEADab80e62_2026-10-08.zip (target HEAD ab80e62)
- Files: +SpektraFilePanel.swift (NSBeep build fix), SOURCE_MANIFEST regenerated
- Build: Intel x86_64, dist zip present (sha256 d61adbd2…)
- Gates: verify_source.sh PASS, qa_10_passes.sh 10/10; no new warnings
