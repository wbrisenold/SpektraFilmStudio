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
