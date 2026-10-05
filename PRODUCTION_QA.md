# Production QA — v0.5.1

`./scripts/qa_10_passes.sh` performs source-level regression passes. **A local Intel x86_64 build using Xcode 26 / the macOS 26 SDK remains the compile/link/Metal gate.** Run the checks below on the built `.app` before release.

## 1. Library / import

- Import 1, 100, 1,000, and, if available, several thousand mixed JPEG/HEIC/TIFF/RAW files.
- Verify first Library paint is not blocked by EXIF/full rendering.
- Verify RAW thumbnails prefer embedded previews when available and persist across relaunch.
- Verify search, sort, folder filters, albums, saved smart collections, ratings, flags, color labels, batch actions, and export inclusion.
- With Auto Smart Cull enabled, verify imported photos begin analysis after thumbnail warmup without freezing Library interaction.
- Enable automatic XMP writes and verify rating/flag/color changes update sidecars; disable it and verify no automatic sidecar write occurs.

## 2. Cull

- Exercise Loupe, Compare, and Survey.
- Analyze a selection and verify progress/cancel, scores, recommendation, focus/exposure metrics, face metrics where detected, stack rank, and reasons.
- Relaunch and verify cached analysis is reused for unchanged source files.
- Confirm Smart Cull never deletes originals or silently applies destructive decisions.

## 3. Cache location and persistence

- Use the default cache and Reveal in Finder.
- Choose another writable local volume, then a mounted external drive; verify the visible `SpektraFilmFast Cache` folder is created at the selected parent.
- Disconnect the external drive and verify the app reports the cache unavailable rather than silently changing the selected custom path.
- Reconnect and verify cache operation resumes.
- Test individual clearing of Thumbnails, Developed Sources, Adjusted Previews, and Smart Cull, plus Clear All.
- Verify disk budget and RAM policy changes do not alter originals or project files.

## 4. Slider / preview behavior

On JPEG and camera RAW:

- Drag RAW Temperature/Tint and representative Color, Film, Print, DIR, Grain, Halation, Diffusion, and Scanner controls.
- Confirm pointer motion stays responsive and no native-render backlog accumulates.
- Confirm mouse-up commits project state once and schedules the exact configured normal preview.
- Confirm the transient interaction proxy is replaced by the exact committed preview and is not reused as the settled adjusted-preview cache entry.
- Set Working File to multiple values and verify ordinary edits reuse the developed working representation instead of redeveloping the RAW on every slider move.
- Set Live Edit Render to 1024, 1280, 1536, and 2048 and verify there is no hidden 720/768 fallback.
- Set Normal Preview to multiple values (for example 1024, 1800, 2560) and verify committed preview dimensions follow the setting rather than a hidden fixed cap.
- Enable Full Resolution Preview and verify it explicitly renders the source at full resolution; turn it off and verify return to the configured normal preview.
- Switch Library → Cull → Edit and between photos; the selected image/look must render without requiring a slider nudge.

### Expanded tone controls

- Exercise Exposure, Brightness, Contrast, Midtones, Highlights, Shadows, Highlight Recovery, Shadow Recovery, Whites, Blacks, White Point, and Black Point independently.
- Verify every slider has a working individual reset and Reset Section returns the entire tone section/curve to neutral.
- Verify Technical, Film Response, and Creative curve presets change only the host tone curve and remain non-destructive.
- Verify Creative WB presets start from the selected image's resolved As Shot or Auto base rather than forcing a fixed Kelvin/tint.

## 5. Auto White Balance

- Test JPEG and multiple camera RAW files under daylight, tungsten, mixed light, and intentionally warm/cool scenes.
- Verify Auto WB actually changes the image when appropriate, Recalculate runs again, and switching into Edit does not require moving another control before the result appears.
- Verify final committed preview/export uses the exact RAW path.

## 6. Scopes and diagnostics

- Test histogram/waveform/parade/vectorscope/skin-vectorscope/CIE inspector modes and scope refresh setting.
- On detected skin, deliberately push Tint toward green and magenta and verify both the viewer overlay status and Skin Vectorscope agree on Too Green / On Target / Too Magenta.
- Verify the Skin Vectorscope shows measured and target markers plus the connector when confidence is sufficient.
- Verify Exposure Warning and Skin Check update the viewer only and never modify `RenderLook`.
- Confirm Before view and exports contain no diagnostic overlay pixels.
- Confirm UI copy does not claim true RAW sensor/photosite clipping.

## 7. Export regression

For JPEG, HEIC, TIFF8, TIFF16:

- one-file and batch export;
- output dimensions match full-resolution render;
- TIFF16 reports 16 bits/component;
- metadata/orientation behavior matches settings;
- deliberate one-file failure does not abort the remaining batch;
- output read-back verification succeeds before success is reported;
- scopes/diagnostics never appear in exports.
- Exercise High Quality, Fast Web, Instagram, Story/Reel/TikTok, LinkedIn, X, and YouTube presets; verify resize/don't-enlarge/metadata behavior matches each preset.

## 8. Project recovery / compatibility / relink

- Open older projects/presets and verify migration/defaults.
- Save/reopen and verify source paths, ratings, flags, labels, albums/smart collections, looks, Cull results, and export settings.
- Force-terminate after edits and verify recovery prompt behavior.
- Move a source folder and test recursive Relink with duplicate-name ambiguity.
- Trigger memory pressure if practical and confirm volatile caches can be released without project/original loss.

## 9. Build / distribution

- Run `BUILD_ON_MAC.command` from this exact source package and verify it completes the Intel x86_64 build.
- Metal `--self-test` and `--studio-soak-test` pass on the locally built Intel x86_64 app.
- `lipo -archs` contains `x86_64`; arm64 is not required.
- Info.plist version is `0.5.1`.
- Release build has Developer ID Application authority + hardened runtime.
- Apple notarization, stapling, and Gatekeeper assessment succeed.
- Release ZIP and `SHA256SUMS.txt` verify after an independent download.

### 9a. Publishing a GitHub release (after each build)

Repeat this every time the app changes, so people can download the app instead of
building it. See `RELEASING.md` for the full checklist.

```bash
# 1. Build clean, so the published artifact is reproducible from the commit.
#    (SPEKTRAFILM_CLEAN=1 forces a from-scratch build and sets incremental_build=no.)
SPEKTRAFILM_CLEAN=1 ./BUILD_ON_MAC.command

# 2. Sanity-check the artifact before publishing anything.
codesign --verify --deep --strict dist/SpektraFilm.app
lipo -archs dist/SpektraFilm.app/Contents/MacOS/SpektraFilm      # expect x86_64
grep incremental_build dist/build-info.txt                        # expect incremental_build=no
unzip -t dist/SpektraFilm-*.zip                                   # expect No errors

# 3. Tag the exact commit you built, and publish.
git rev-parse --short HEAD            # record this; the release must point at it
gh release create v<VERSION> \
  dist/SpektraFilm-<VERSION>-macOS-intel.zip dist/SHA256SUMS.txt \
  --target main \
  --title "SpektraFilm <VERSION> — Intel (x86_64) macOS app" \
  --notes-file RELEASE_NOTES.md

# 4. Confirm the published bytes match what you built.
gh release download v<VERSION> --pattern '*.zip' --dir /tmp/relcheck
shasum -a 256 /tmp/relcheck/*.zip dist/SpektraFilm-<VERSION>-macOS-intel.zip
```

Release notes must state the Gatekeeper workaround, because the local build is
ad-hoc signed and not notarized. See the "first open" section of `RELEASING.md`.

The tag must point at the commit that was built, so `git rev-parse v<VERSION>^{commit}`
must equal `git rev-parse origin/main`. Do not move a published tag; publish a new version instead.

## 10. Studio soak

Run at least a one-hour real edit/cull/export session with repeated photo switching, Cull analysis, cache hits, scopes, RAW edits, and exports. Watch for runaway RAM/thread count/CPU after idle, stale-frame flashes, blank previews, or UI hangs.
