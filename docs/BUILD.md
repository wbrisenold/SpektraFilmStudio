# Build and validate

Version 0.6.8 targets macOS 15+ and Intel x86_64. This repair was built on macOS 15.7.9 with SDK 26.2 and Swift 6.2.4. Install Apple Command Line Tools, Python 3 and Rust/rustup as required by the dependency bootstrap. The supplied Metal library is copied into the app. The spectral native core and generated curves are vendored. First-time runtime/model and pinned Rust dependency preparation needs internet access; cached model files are checked before reuse.

## Build

From the repository root:

```bash
./PREPARE_STAGE3_AI_MODELS.command
./BUILD_ON_MAC.command
```

Or run `scripts/build_app.sh` directly after preparation. Keep at least 8 GB free for the default build gate. Do not select an arbitrary executable from an old scratch folder: the script resolves the exact SwiftPM product. The app and ZIP stay in `dist/`. `dist/build-info.txt` and the app Info.plist embed the full source commit and dirty state.

SAM 2.1 Tiny is pinned by `Resources/SAM2TinyManifest.json`. `python3 scripts/prepare_sam2.py --check-only` checks all nine files. Preparation downloads about 80 MB, verifies each size/hash, and uses Core ML to compile the packages. The compiled models are bundled. Legacy MobileSAM, BiRefNet and MODNet files remain locally if present but are excluded from the app. The current editor uses Redlamp Vision/SAM3/depth/matting providers; legacy model weights are not packaged. Install optional exact models in Settings → Models. Models prefer the discrete GPU through Core ML. GPU model compatibility remains under validation; no CPU-only retry is used.

## Source checks

```bash
bash scripts/verify_source.sh
bash scripts/qa_10_passes.sh
python3 -B scripts/test_picker_application.py
```

Regenerate `SOURCE_MANIFEST.sha256` after changes using the exclusions in `verify_source.sh`; include new screenshots and documentation. Static source checks do not replace compilation or runtime checks.

## Native runtime checks

Launch independent test instances through Launch Services, capturing stdout/stderr. Available flags: `--picker-smoke-test`, `--self-test`, `--studio-soak-test`, `--mask-overlay-self-test`, `--ux-smoke-test`, and `--sam2-smoke-test --sam2-fixture /path/to/Meta/truck.jpg`. UX capture accepts `--ux-fixture /path/to/photo.jpg`. Test fixtures must be suitable for each assertion; the SAM test expects Meta’s public truck example. Test instances isolate recovery/history and must not replace or quit a user’s unsaved session.

The SAM smoke test checks actual object coverage, background rejection, orientation, repeat/changed prompts and invalid coordinates. The Intel Radeon GPU currently produces non-finite SAM2 image embeddings, including a higher-precision diagnostic variant. On this dual-GPU Mac, the exact model passes the object smoke test on Intel UHD 630; SAM2 selects that GPU. Invalid output is rejected. Full-resolution file encoding and external service integration require separate media/provider validation beyond export-boundary source checks.

## Signing

Local builds are ad-hoc signed and verified. Set `SPEKTRAFILM_CODESIGN_IDENTITY` to an available Developer ID identity for distribution signing, then use the notarization scripts with your account. Ad-hoc signing is not notarization. See [Release procedure](RELEASING.md).

Integrated masking: `--mask-integration-test --sam2-fixture /path/to/truck.jpg --sky-fixture /path/to/photo-with-sky.jpg`. Add `--test-optional-models` after installing SAM 3, DA3, V2 Small and ViTMatte. A developer test store can be selected with `--mask-model-root /path/to/verified-models`; `scripts/prepare_mask_models.py --destination /path/to/verified-models` downloads the exact manifests. Use a real landscape for Sky/Landscape checks: the truck fixture intentionally contains no sky.
