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
