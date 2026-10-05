# Build SpektraFilm v0.5 locally on macOS

You do not need a GitHub repository or GitHub Actions. `Resources/SpektraFilm.metallib` is already bundled.

## Requirements

- macOS with Xcode 26 / macOS 26 SDK
- Xcode Command Line Tools
- Internet access on the first build so the pinned native source can be fetched

## One-click build

1. Unzip this folder on the Mac.
2. Double-click `BUILD_ON_MAC.command`.
3. macOS may ask whether to open the command file; approve it.
4. When the build completes, Finder opens the `dist` folder.
5. Launch `SpektraFilm.app`.

The build creates an Intel x86_64 application. Apple Silicon is intentionally not built for this release. The included `.metallib` is copied directly into the app bundle; the build does not recompile the Metal shader library.

## Optional production signing

By default the app is ad-hoc signed for local use. If you have a Developer ID identity, set `SPEKTRAFILM_CODESIGN_IDENTITY` before running `scripts/build_app.sh`, then use `scripts/notarize_app.sh` for notarization/stapling.
