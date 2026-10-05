# v0.6 production-hardening status

The source now includes verified dual-destination ingest, project-scoped background jobs,
large-import/autosave fixes, durable export recovery/Stop, batch look sync, memory-pressure
shedding, and the v0.5.4 skin/diagnostic/WB-to-Skin work.

**Production approval still requires the exact Intel macOS build, runtime tests, disk-full/
disconnect tests, crash-recovery tests, and a multi-thousand-RAW wedding-scale soak.**

# Production Readiness Matrix — v0.5.1

| Audit item | v0.5.1 disposition | Gate |
|---|---|---|
| Library workflow incomplete | Completed search/sort/folders/albums/smart collections/batch decisions/XMP/export inclusion | source QA + manual Library QA |
| Cull workflow incomplete | Completed local bounded analysis + Loupe/Compare/Survey + persistent result cache | source QA + manual Cull QA |
| Auto-cull preference disconnected | Wired import completion to targeted Smart Cull analysis | source QA + import QA |
| Auto-XMP preference disconnected | Wired rating/flag/color changes to optional XMP writes | source QA + XMP QA |
| Old sub-1K live-preview path produced unreliable results | Replaced with persistent fixed 1080 px linear working files for both live and idle editing | source QA + slider QA |
| Transient proxy could be mistaken for settled output | Proxy is display-only and not persisted as adjusted preview | source QA + visual settle QA |
| Cache location/control incomplete | Custom local/external folder, visible status/path, reveal/default, per-store clear/all clear | source QA + removable-drive QA |
| Cache schema could reuse stale approximation entries | Developed/rendered schema generations bumped | source QA |
| UI branches diverged | Newer studio shell merged into v0.4 Library/Cull/cache feature branch | source QA + manual UI QA |
| Scopes crowded edit controls | Dedicated Scopes inspector | manual UI QA |
| Auto WB regression risk | Functional v0.4 Auto WB/recalculate path retained | source QA + RAW/JPEG visual QA |
| Export contamination by diagnostics | Diagnostics remain separate from `RenderLook` / `ExportWriter` | source QA + export QA |
| Intel x86_64 binary/runtime not provable on Linux source host | Intentionally unresolved here | Local Xcode 26 / macOS 26 SDK Intel x86_64 build |
| Distribution trust | Developer ID + hardened runtime + notarization/stapling/Gatekeeper required | Local Mac release gate |

## Release status

This source tree is ready for the macOS build/runtime gate, not a claim that a final signed `.app` has already been executed in this Linux environment. The release commit must pass source checks, Universal compile/link, Metal self-test and renderer soak, signing/notarization, and `PRODUCTION_QA.md` before being called studio-production-ready.
