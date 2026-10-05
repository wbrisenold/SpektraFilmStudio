# SpektraFilmFast 0.5.2 — Studio Workflow

## v0.5.2 — 1080 workfile + People Groups

- Fixed the interactive architecture to one **1080 px long-edge linear workfile** for both live dragging and idle editing; no automatic 1800/2K settle render.
- Full Resolution Preview and Export remain the only paths that reopen the original source at full resolution.
- Added local **People / Face Groups**: Apple Vision face detection + local image feature-print clustering, persisted as project groups and exposed in the Library sidebar. No face data leaves the Mac.
- Added a visible, undoable **Reset All** button that resets only image edits, leaving ratings, flags, Client Picks, metadata, and originals intact.
- Applied the latest GitHub `main` compiler fixes from base commit `df0eb829c9921b3f7db0d92db34fc12a3a386d63`.
- Removed the obsolete adaptive edit-resolution path and updated QA to enforce the fixed 1080 policy.


## Library and metadata

- Completed the Library workspace with search, sorting, folder filters, albums, saved smart collections, ratings, flags, color labels, batch actions, and export inclusion.
- Added persistent dual-size thumbnails with RAW embedded-preview preference and bounded background warmup.
- Added XMP sidecar read/write workflow and optional automatic sidecar writes for rating/flag/color changes.
- Wired the existing “Auto-analyze imported photos” preference so new imports can begin Smart Cull analysis after thumbnail warmup.

## Smart Cull

- Completed Loupe, Compare, and Survey Cull views.
- Added local score/recommendation, focus, face-focus, exposure, face count, stack rank, clipping percentages, possible-blink review cue, and explainable reasons.
- Cull analysis reuses warmed image data and persists in its own disk cache.
- Analysis never deletes originals or overrides the photographer’s manual decisions.

## Preview and cache architecture

- Removed the separate hard-capped working-preview path.
- Committed edits now schedule the exact native renderer at the configured normal preview size (1800 px default).
- The low-resolution interaction proxy exists only while dragging, is not persisted as an adjusted preview, and is replaced by the exact committed preview.
- Bumped developed-source and rendered-preview cache schema generations so stale approximation-era entries are not reused.
- Added persistent developed-source, exact adjusted-preview, thumbnail, and Smart Cull caches under one centrally budgeted root.
- Added custom cache-folder selection for writable local or mounted external volumes, visible path/status, Reveal in Finder, Use Default, and per-store/all cache clearing.

## Studio UI

- Merged the newer studio shell into the v0.5 workflow without dropping v0.5 features.
- Added a cleaner Library / Cull / Proofs / Edit / Export navigation shell.
- Added a three-pane editor and dedicated Scopes inspector for waveform/parade/vectorscope-style monitoring.
- Kept Exposure Warning and Skin Check as viewer-only diagnostics excluded from export.
- Preserved the functional Auto White Balance path and recalculation control.

## Reliability and release gates

- Preserved autosave/recovery, dirty-project protection, missing-media relink, verified full-resolution export, Intel x86_64 macOS packaging, and the pinned renderer core `8f6651858f439a99b7202b4b8dea59e344dadf5d`.
- Updated source QA to require exact committed previews and reject the removed capped working-preview behavior.
- Final compile/link/Metal validation remains the local Xcode 26 / macOS 26 SDK Intel x86_64 build gate.

## v0.5.1 — Studio Workflow

This release turns the v0.4 Library/Cull editor into an end-to-end studio workflow without removing the existing SpektraFilm controls.

- White Balance sliders are always available from As Shot, Auto, or Custom. As Shot/Auto use their resolved neutral as the slider zero point, live WB is applied before the film render, and the Kelvin control uses reciprocal-temperature behavior.
- Added sourced Exposure + Tone Curve controls, with Alcedo-derived ACEScc exposure semantics and darktable-derived curve preset points.
- Added Crop & Geometry with a real viewer crop overlay, presets for photo/print/social/cinema (including 1.43:1 and 1.90:1 IMAX), auto straighten/perspective correction, auto crop, offsets, scale, flips, and guide overlays.
- Scopes are always available in Edit and use a cleaner monitor design. Added a dedicated skin-only vectorscope.
- Skin Check now isolates people first and applies published YCbCr/HSV skin classification only inside the subject region. The overlay is redesigned as a restrained grading aid rather than a bright false-color mask.
- Integrated ProofDock directly as the Proofs workspace: render current edits as proofs, create/copy share links, set cover, enforce optional password/selection limits, preserve heart/fullscreen/Finish Selection behavior, regenerate client links, and sync Client Picks back into Library.
- Added beginner hover help, individual slider resets, section resets, Undo/Redo and Copy/Paste Look controls.
- Existing Library, Cull, SpektraFilm controls, diagnostics, presets, caches, recovery/relink, and export behavior remain available.

### Export workflow additions
- Added sourced export presets: RapidRAW High Quality and Fast Web defaults.
- Added a Social Media preset group with Instagram, Story/Reel/TikTok, LinkedIn, X, and YouTube target dimensions sourced from OpenPost's open-source image-editor preset table.
- Added full-size / long-edge / width / height / fit-inside resize modes with high-quality Accelerate scaling and a Don't Enlarge guard.
- Added optional GPS stripping while retaining other metadata.
- Social presets preserve composition and never silently crop; exact platform dimensions are produced when the image's Crop aspect matches the selected social preset.

## v0.5.1 — final studio hardening

### Tone and look development

- Added separate Brightness, Midtones, Highlight Recovery, Shadow Recovery, White Point, and Black Point controls while preserving Exposure, Contrast, Highlights, Shadows, Whites, Blacks, and the point curve.
- Added beginner hover explanations, individual reset, and Reset Section behavior for the expanded tone stack.
- Expanded Tone Curve presets into Technical, Film Response, and Creative groups. Film Response presets describe master-curve toe/shoulder character rather than claiming exact named-stock emulation.
- Added per-image relative White Balance preset groups: technical As Shot/Auto bases plus original creative recipes including Golden Hour, Sunset, Sunrise, Blue Hour, Candlelight, Moonlight, interiors, weather, editorial, and film-warm variations.
- Added Color Density controls informed by Primera-style color-density behavior.

### Diagnostics

- Exposure Warning and skin analysis are enforced on the final post-film/post-geometry rendered buffer rather than the developed RAW-side source.
- Exposure Warning distinguishes near-limit risk from hard clipping.
- Skin overlay and Skin Vectorscope share one confidence-weighted detected-skin measurement and report Too Green / On Target / Too Magenta.
- Skin Vectorscope shows measured and target indicators with a connector and retains the common polished scope design.

### Performance and crop interaction

- Added a persistent linear working-file preference (2048 px default) so ordinary editing reuses developed image data instead of repeatedly redeveloping the original.
- Live edit resolution is bounded to 1024–2048 px; old 720/768 values are migrated upward.
- Latest-request-wins scheduling, selected/neighbor warmup, and display-only pointer feedback prevent stale render backlogs.
- Crop frame move/resize is overlay-only during pointer movement; geometry resampling settles after the gesture.
- Auto Fill solves minimum scale needed to cover the crop after geometric transforms, preventing black wedges when the geometry is solvable by zoom.

### Library, Proofs, and export

- Library keyboard shortcuts and right-click actions apply to highlighted multi-selections.
- Current selection, Pick/Reject, Client Pick, and Queued for Export use separate semantics/visual states.
- Corrected thumbnail orientation handling and invalidated the old orientation cache schema.
- Preserved the integrated ProofDock short-link/client-selection workflow and removed product-specific event language.
- Added High Quality / Fast Web export presets and platform output presets for Instagram, Stories/Reels/TikTok, LinkedIn, X, and YouTube.

### Cleanup and handoff

- Removed unused legacy UI declarations and development debris while retaining shared live components.
- Updated `AI_HANDOFF.md`, source attribution, open-source support links, contribution guidance, QA, and release documentation.
- Project README now openly discloses that the application was vibe-coded and encourages contributors to improve or extend it.
