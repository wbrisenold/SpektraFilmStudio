# SpektraFilmStudio interaction system

Native photography workbench. Preserve StudioPalette semantic macOS colors, system typography, StudioLayout dimensions, split views, keyboard focus and accessibility. One consistent system across all workspaces; no decorative website chrome or new branding.

## Shared rules

- Global navigation is Home, Library, Cull, Proofs, Edit, Export. Home is visibly selected only on the project launcher. Workspace tabs reflect the actual page.
- Common actions use visible verb labels: Open Project, Import Photos, Import Folder, Export Photos. Local import opens the browser immediately. Backup/cloud import is optional, clearly named, and fits on one scrollable setup sheet.
- Each empty state explains the missing input and provides a direct recovery action. Filtered-out content offers Reset Filters. Preserve the user's project and selections on cancellation.
- Basic export settings and destination are visible by default. Photo selection is reachable from the export toolbar even when the browser is hidden. Advanced file naming and metadata stay available behind disclosure controls.
- Edit shows labeled panel controls and a persistent Export Photo action. Cull explains review modes and shortcuts. Proofs starts from available photos and keeps publishing controls distinct from local links.
- Standard default/cancel keyboard actions on sheets. Disable actions while their work is in progress and explain empty selections. Long panels scroll; toolbars must fit the app's 1024-point minimum window width.
- UI copy describes photography tasks, not implementation internals. Technical details live in tooltips, diagnostic disclosures and build provenance.

## Implementation tokens

StudioPalette is the color token source; StudioLayout is the layout token source. macOS system fonts are used throughout. Existing compact 10–14-point panel spacing and native bordered primary/secondary button styles remain consistent. This is a SwiftUI application; no unused CSS or web token files are introduced.

## Review

Hallmark pre-emit critique target: philosophy 4, hierarchy 4, execution 4, specificity 5, restraint 5, variety 3. Final delivery records visual and runtime verification limits rather than assuming pixel correctness.

## Redlamp reference and final workflow

Reference: https://github.com/pdcgomes/redlamp at `0ed3a59211e4128111f2c8ba11bc5d249b0cb8dd`. The final design preserves the user's RAW → FILM → MASK tabs and the nested RAW (WB/Light/Crop/Optics) and FILM (Stock/Negative/Print/Output) stage tabs. Selected stage controls remain visible, with restrained typography and flat divisions. No collapsible replacement of those tabs.

Cull is photo-first with a compact review toolbar, filmstrip and persistent pick/reject/rating controls. Redlamp has no dedicated Cull page; this is a local adaptation of its photo-first hierarchy. Export uses a photo preview and a grouped settings dialog, with exactly one destination chooser. Guided import requests the file/folder browser immediately; advanced storage and cloud options share one optional sheet.

The masking providers, matting and model contracts are adapted from Redlamp source under MPL-2.0. Exact model manifests, licenses and revision evidence are recorded in IMPLEMENTATION_SOURCES.md. Intel uses CPU execution for models that cannot produce reliable output on its GPU. The film renderer and project/library/proofs architecture remain Spektra's.

Validation includes native compact/wide captures, restored stage tabs, immediate source browsing, a single export-location source gate, real Core ML inference and CPU/GPU coverage parity. Runtime results are recorded separately from compilation; no universal performance guarantee is implied.
