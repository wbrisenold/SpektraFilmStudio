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
