# 2026-10-08 reliability audit

The picker crash repair was pushed first as f0d6c96d2f54f865b1d069cb0f2acb725362dcf1. This follow-up audits the application entry points, picker/save/quit lifecycle, cloud copy and transfer code, credential setup, import/export protection, project/mask decoding, build packaging and Rust bridge. The production source gates also cover Library/Cull/Proofs/Edit, cache budgets, rendering, export isolation, migration and resources. This is a risk-focused source audit, not a claim that every possible defect has been eliminated.

## Confirmed fixes

- Python original and ZIP migration no longer identify matching byte counts as verified contents. Existing originals require a matching SHA-256 (manifest or prior completed journal; ZIP entries are read through CRC validation). Newly uploaded files are downloaded and hashed on Oracle before the completion journal is updated. This adds remote bandwidth and time. An unverified conflicting object is preserved and rejected for manual review rather than overwritten or silently accepted. Failed uploads may leave an unverified remote object, but retries cannot report that object as successful by size alone.
- Upload subprocess stderr is discarded instead of left in an unread pipe that could deadlock the upload. Failures still propagate a nonzero exit; secrets are not included in displayed process diagnostics.
- Cloudflare transfer streams enforce declared byte count while streaming, rejecting both short and oversized streams. Existing legacy objects lacking verification metadata are rejected for review and are not offered for download as verified originals. No Worker was deployed during this repair.
- Cloud library copies compare contents before accepting an existing destination. Conflicting files are preserved and explicitly rejected. Streams close and byte counts are verified before publishing a new destination. GUI smoke tests exercise initial copy, idempotent copy, and equal-size conflict preservation.
- Oracle terminal output and exit callbacks are scoped to a session generation, so a stopped session cannot expose late output or stop a replacement session. Input write failures are handled. Credential import rejects option-like usernames/hosts, discards unused process output rather than filling pipes, and stops remote installation if permission or backup steps fail. No credentials were transferred during tests.

## Validation and limits

Run scripts/qa_10_passes.sh, the Oracle Python tests, CloudTransfer Node tests and the built application's --picker-smoke-test, --self-test and --studio-soak-test. The delivery report records actual outcomes and exact commit provenance. Rust bridge tests cover JSON capacity negotiation, descriptor serialization, malformed input and non-finite controls. Native semantic entry points reject null paths, excessive model dimensions and non-finite point coordinates before accessing buffers.

Tests use temporary project/copy fixtures and mocked cloud services. Live Oracle SSH, Adobe authorization, R2 and iCloud provider behavior require the user's authenticated services and were not exercised. The app is locally ad-hoc signed, not Developer ID notarized. The two pre-existing Swift warnings in LensCharacterPanel.swift and PresetBrowserView.swift were addressed. System file-picker history and mounted volumes were preserved; the repair uses an in-app browser to bypass the observed macOS filepicker XPC initialization failure.

## Additional crash and privacy boundaries

- Malformed proof-server Content-Length values cannot overflow request indexing. Ambiguous repeated headers and chunked framing are rejected; requests have a bounded lifetime. Host-derived HTML is escaped. Password-protected covers require gallery authorization, token storage is bounded, and proof state containing passwords is restricted to owner access. Public-tunnel callbacks are generation-scoped and parse split output safely.
- Corrupt float-cache dimensions are rejected before integer multiplication; valid cache round trips remain supported. Invalid decode extents and unsafe memory sizes fail with a readable error.
- Duplicate photo IDs in project files are rejected before identity dictionaries or view lists are built. Late project opens and folder scans cannot apply to a replaced workspace, and an in-flight open does not discard edits made while it was decoding. Opening standalone photos detaches the old cloud session.
- Export sequence overflow and unsupported dimensions fail before numerical conversion or allocation. Preview dimensions and persisted JPEG quality are bounded. Large output estimates avoid integer overflow. Metal crop validation avoids overflowing additions. Native semantic tensor dimensions and pointers are checked; the Rust bridge rejects non-finite control values.
- Preset recent-ID dictionaries tolerate duplicates. Minor compiler warnings and an incorrectly escaped remote-exit message were corrected.

## Application-wide usability changes

The native design system is documented in DESIGN.md. Home, Library and toolbar Import Photos open the file browser directly; Import Folder or Card opens the folder browser. Optional backup/cloud import is a single scrollable sheet instead of Source/Storage/Review/Started pages. The existing cloud setup remains a separate specialist workflow.

Library filter changes clear stale collection filters and the empty state offers Show All Photos. Cull uses Single Photo/Compare/Overview labels, accessible navigation actions and an actionable empty state. Edit labels its panel buttons and keeps Export Photo available when the filmstrip is hidden. Export shows basic settings by default, moves destination first, exposes Select Photos in the toolbar, and opens its folder chooser directly. File naming and metadata remain in an optional disclosure. Quick Export supports every resize mode and standard default/cancel keys. Proof gallery creation starts with available photos, image-quality controls are optional, local versus internet links are explicit, and gallery deletion requires confirmation. Settings describes actual optional scopes and moves specialist color handling into a disclosure. Home no longer synchronously probes each recent project's possibly unavailable drive while rendering.

Final validation includes real native view snapshots at compact and wide desktop window sizes. These are review evidence, not proof of every possible display size or external-service integration.

## Restored controls and Redlamp masking integration

RAW/FILM/MASK and their stage tabs are preserved. Cull uses compact review controls and persistent decisions; Export opens grouped delivery settings with one destination chooser. Optional storage no longer blocks direct import.

The current AI path replaces legacy semantic parsers with Redlamp's Vision/SAM2/SAM3/depth/matting providers and exact versioned manifests. Bitmaps and recipes persist together; updated and pasted masks recompute from the unedited photo. Intel binary16 conversion and model execution are adapted for this platform. Empty connected regions remain empty. Depth selection is evaluated in the fused coverage kernel, and range data is not altered by edge refinement. Update AI Masks invalidates computed model results. Histogram clipping metrics update independently of overlay visibility. See the delivery validation report for actual inference results and untested camera/portrait fixtures.

Final masking safeguards bound shaped-raster caches to 128 MiB and GPU raster caches to 256 MiB, in addition to entry limits. Subject and Background reuse one canonical foreground matte, avoiding duplicate ViTMatte inference. Installing a model invalidates provider caches. ViTMatte rejects non-finite or malformed alpha tensors. Intel executes optional masking models on the CPU because MPS execution stalled during validation; full-resolution refinement can take minutes. Startup has a once-only path independent of view appearance and presents a workspace when restoration produces no window.

Refine Edges follows the provider-specific creation path, including optional ViTMatte for whole subjects/people. Refine Edge Brush limits work to the stored strokes; full-edge refinement subsequently replays them. Background refinement operates on the foreground matte before inversion. SAM 3 people parts retain closed-form refinement while coarse Vision/iPhone parts use guided full-size refinement.
