# v0.5.2 — Ten-pass production-source QA report

`./scripts/qa_10_passes.sh` covers these source-level gates:

1. Swift syntax and SwiftPM manifest.
2. Shell/workflow syntax and release prerequisites.
3. Pinned native renderer/resources and known release pitfalls.
4. Library import, persistent thumbnails, albums/smart collections, XMP hooks.
5. Smart Cull engine/workspace, bounded analysis, and persistent Cull cache.
6. Persistent working-file/edit contract: no sub-1K fallback, no persisted transient interaction frame, expanded tone controls, latest-render-wins scheduling.
7. Developed-source/adjusted-preview caches, cache-location controls, disk budgeting, and memory pressure.
8. Auto WB, scopes, Exposure Warning, and Skin Check integration.
9. Export isolation and verified JPEG/HEIC/TIFF8/TIFF16 paths.
10. v0.5.2 version/resource/source-manifest/runtime-distribution gates.

These source checks do not substitute for a local macOS 26 SDK Universal build, the Metal self-test/renderer soak, Developer ID signing/notarization, or the real studio soak described in `PRODUCTION_QA.md`.
