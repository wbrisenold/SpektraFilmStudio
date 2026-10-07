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

