# Fast baseline / unified Export regression contract

## Protected reference

- Source commit: `60c7f4673a72ed7b974ff9ba50e93f84925097f7`
- Source message: `ui: Redlamp source audit — floating scopes, Cull/Library nav, export sections`
- On the Mac installer, **before any source modification**, archive to `OUTPUT/SAFE_BASELINE/SpektraFilmStudio-FAST-UNCHANGED-60c7f467.zip` and preserve a local Git branch `preserve/fast-2026-10-10` and annotated tag `fast-baseline-2026-10-10`.
- The original screenshot of the fast baseline is under `OUTPUT/SAFE_BASELINE/FAST_BASELINE_EXPORT_SCREENSHOT.png` and inside this installer as `reference/FAST_BASELINE_EXPORT_SCREENSHOT.png`.
- An attempted remote GitHub archival branch failed with a 403 (integration write permission), so **the protected remote branch is not claimed to exist**.

## Keep these in every subsequent revision

1. Redlamp custom slider geometry, values, drag/fine adjustment and keyboard controls.
2. Persistent GPU-resident Metal editing preview and newest-request-wins scheduling.
3. 1080 px idle + live preview, no unnecessary high-resolution refines while dragging.
4. Floating, draggable scopes with correct aspect ratio, right-side adjustment inspector not squeezed.
5. Presets/Photos on the left, including Photos filters; improved left-side Cull photos and popover filters.
6. Omni Search and its keyboard shortcut; no new modal cross-wire with Command-K.
7. Masks, cropping, overlays, RAW controls and the exact color-managed export writer are unchanged.
8. Existing export presets and size/paper/color/naming/metadata settings persist unchanged; no implicit overwrite.
9. All Export triggers, from all four workspaces, File menu and legacy `.export`/Omni routes, show **one and the same** sheet component.
10. Popup has live crop/fit delivery preview, selectable photo set, selected count, Location, File, Size, Metadata and export queue progress.
11. User's existing selected photos are never silently replaced when opening the Export popup; export may run in background after closing.
12. The experimental ART-style LUT is **opt in**; native exact remains default, and full-resolution exports use the original renderer.

## Quality gates

Run `python3 scripts/qa_export_dialog.py` and `bash scripts/qa_10_passes.sh` on the patched Mac checkout, then `SPEKTRA_BUILD=1` or `bash scripts/build_app.sh` to compile for Intel. Swift parse-only QA does not prove cross-file type correctness.

Performance parity benchmark: same Intel Mac, same 140-photo project, same 1080 px preview and cached photo, measure cold launch, median slider latency, 95th-percentile interactivity, photo selection latency, GPU frame time, Export popup opening delay, and 1/10/140 JPEG export throughput. Compare to the archived baseline (record numerical results, not subjective impressions). Reject any new GPU stall or sustained >10% regression unless the user approves. The source snapshot is not a benchmark and cannot establish those numbers.

## UX acceptance

- Export button always accessible in Library, Cull, Proofs and Edit, including after returning from Settings.
- Export is a single Redlamp/Omni-glass popup, NOT a fifth persistent workspace tab.
- Preview reacts when size or crop-to-fill settings change, before exporting anything.
- Photo chooser is popover-on-demand to leave the preview and settings uncluttered.
- Folder picking, batch presets, existing-file safety and queue resume/retry continue working.
- Close popup during a job then reopen it to inspect progress; no duplicate queue or job is created.

## 2026-10-10 direct Redlamp source follow-up

Audited `pdcgomes/redlamp` commit `657beb41d148a8f66916123f961e612b95c1a047`, specifically `packages/RedlampUI/Sources/Export/{ExportSheet.swift,ExportSheetSections.swift,ExportPlan.swift}`. The popup is **now a separate SwiftUI view** using native `.formStyle(.grouped)` and actual `Section` controls; a large SpektraFilm live output preview occupies the left side. The old ExportWorkspaceView is not embedded in the modal. The queue is hidden until processing or completed/failed progress exists. Fit-Inside preview uses the image, not a drawn yellow target box; resizing delivery-only parameters no longer forces an extra native spectral render.

The upstream Redlamp sheet is 540×720 and does not have a large live preview or batch set; those two controls are explicitly SpektraFilm additions, not falsely attributed to Redlamp. Native export engine, metadata and original-vs-export color matching are unchanged.

**LUT action fix:** The action immediately invokes `prepareSelectedFilmLUT`, first checking actual native renderer eligibility, showing progress then a blocking reason such as spatial DIR, grain, halation, or scanner statistics, or a successful cached/generated status. It never quietly changes film look settings to make a LUT eligible. A blocked look continues through native spectral Metal and remains visually accurate. A LUT-ready status only applies to compatible subsequent live frames; settled exact preview continues to show native renderer.

**Not validated here:** Intel macOS SDK build, actual Metal execution and visual screenshots. The user must run the bundled Mac build gate before release.
