# Releasing SpektraFilm

How to publish a pre-built app so users don't have to build it themselves.
The full checklist lives in `PRODUCTION_QA.md` §9a; this file is the reference.

## Why publish a zip

The local build produces an **ad-hoc signed, un-notarized** app. Anyone who
clones and runs `BUILD_ON_MAC.command` also needs macOS 26 / Xcode 26 and ~10
minutes. Publishing the zip removes both barriers — they just download and drag.

The cost is one honest paragraph in the release notes telling people how to clear
Gatekeeper once. That is cheaper than making everyone install Xcode.

## Before you build

Bump `VERSION` in the repo root. The build stamps the version into
`Info.plist`, the zip filename, and `build-info.txt`, and the source gate
rejects a malformed `VERSION`.

Build from a clean tree on `main`, so the artifact matches the commit you tag:

```bash
git checkout main && git pull --ff-only
git status --porcelain      # must be empty
```

## 1. Build

```bash
SPEKTRAFILM_CLEAN=1 ./BUILD_ON_MAC.command
```

`SPEKTRAFILM_CLEAN=1` matters: it forces a from-scratch build and writes
`incremental_build=no` into `dist/build-info.txt`. An incremental build
(`incremental_build=yes`) is fine for your own testing but must not be published —
it can carry stale object files, so two people building the same commit can get
different bytes.

> The build needs only macOS + Xcode 26. No network, no Python.

## 2. Verify before publishing

```bash
codesign --verify --deep --strict dist/SpektraFilm.app   # must pass
lipo -archs dist/SpektraFilm.app/Contents/MacOS/SpektraFilm   # x86_64
grep -E 'version|incremental_build|codesign_identity' dist/build-info.txt
unzip -t dist/SpektraFilm-*.zip                          # "No errors detected"
```

Then confirm the zip restores a working app:

```bash
mkdir -p /tmp/vfy && unzip -q dist/SpektraFilm-*.zip -d /tmp/vfy
codesign --verify --deep --strict /tmp/vfy/SpektraFilm.app
lipo -archs /tmp/vfy/SpektraFilm.app/Contents/MacOS/SpektraFilm
rm -rf /tmp/vfy
```

Check the same things `PRODUCTION_QA.md` §9 asks for. Note that
"notarization and Gatekeeper assessment succeed" **cannot** pass for a local
build — see the limitation below.

## 3. Write the notes

Start from the existing release notes and update the version, the commit, and the
build number. This block is the part users actually need:

````markdown
### Install

1. Unzip `SpektraFilm-<VERSION>-macOS-intel.zip`.
2. Drag `SpektraFilm.app` into your **Applications** folder.
3. Launch it.

### If macOS blocks it on first open

This build is **ad-hoc signed and not notarized**, so Gatekeeper will show:

> "SpektraFilm" cannot be opened because the developer cannot be verified

That is expected — it is not a corrupt download. Clear it once:

**Option A — right-click → Open**: right-click the app in Applications, choose
**Open**, then **Open** again in the dialog.

**Option B — from Terminal:**
```
xattr -dr com.apple.quarantine /Applications/SpektraFilm.app
```

You only do this once per Mac.

### Requirements

- macOS 15.0 or newer
- Intel; on Apple Silicon run `softwareupdate --install-rosetta` first
- No other dependencies, no network needed
```

Always keep two honest notes in there:

- **Presets are per-Mac.** Settings live in
  `~/Library/Application Support/SpektraFilm/presets.json`, not inside the app, so
  they do not travel with the download.
- **It is unsigned.** Unsigned apps cannot be distributed through the Mac App Store.
````

## 4. Publish

```bash
git rev-parse --short HEAD     # record this
gh release create v<VERSION> \
  dist/SpektraFilm-<VERSION>-macOS-intel.zip dist/SHA256SUMS.txt \
  --target main \
  --title "SpektraFilm <VERSION> — Intel (x86_64) macOS app" \
  --notes-file RELEASE_NOTES.md
```

`--target main` is required; a raw commit SHA is rejected by the API
(`target_commitish is invalid`).

Never re-point or overwrite a published tag. Ship a new version instead.

## 5. Verify what you published

```bash
gh release download v<VERSION> --pattern '*.zip' --dir /tmp/relcheck
shasum -a 256 /tmp/relcheck/*.zip dist/SpektraFilm-<VERSION>-macOS-intel.zip
```

The two hashes must match. This catches a truncated or stale upload — it has
already happened once in this project's history (a stale artifact hash).

Also confirm the tag lands on the built commit:

```bash
git fetch --tags origin
git rev-parse v<VERSION>^{commit}   # must equal git rev-parse origin/main
```

## Notarization (removes the Gatekeeper warning)

Everything above publishes an app that works but shows a Gatekeeper warning.
`scripts/notarize.sh` does the whole job. It will not run until you supply an
Apple Developer account — that part is genuinely not automatable.

```bash
./scripts/notarize.sh --check     # report what's missing; changes nothing
./scripts/notarize.sh --run       # sign → submit → staple → verify → re-zip
```

`--check` is safe to run any time and is the fastest way to see what's left.

### One-time setup

1. **Enrol** in the [Apple Developer Program](https://developer.apple.com/programs/enroll/)
   ($99/yr). Individual or Organisation both work.
2. **Create a Developer ID Application certificate.**
   Xcode → Settings → Accounts → Manage Certificates → *+* → **Developer ID**.
   Or import an existing `.p12`:
   ```
   security import cert.p12 -k ~/Library/Keychains/login.keychain-db
   ```
3. **Store notary credentials.** These are never written into the repo:
   ```
   xcrun notarytool store-credentials spektra --apple-id you@example.com --team-id TEAMID
   export NOTARY_PROFILE=spektra
   ```
   For CI, use an App Store Connect API key instead:
   ```
   export NOTARY_KEY_ID=... NOTARY_ISSUER_ID=... NOTARY_KEY_PATH=/path/AuthKey_xxx.p8
   ```

Then `./scripts/notarize.sh --check` should be clean, and `--run` publishes a
zip that opens with no warning and no `xattr` step.

### What the script does

Signs with `--options runtime --timestamp` (both required for notarization),
submits with `--wait`, staples, checks `spctl` reports *notarized*, then rebuilds
the zip and `SHA256SUMS.txt` from the stapled bundle.

Two details it handles that are easy to get wrong by hand:

- **`notarytool` will not accept a bare `.app`** — only `.zip`/`.dmg`/`.pkg`. The
  script zips for submission, then rebuilds the distributable zip *after*
  stapling. Submit the pre-staple zip and your published copy stays unstapled.
- **`--timestamp` is mandatory** for Developer ID. Without it the signature is
  not valid for notarization, and there is no error at signing time.

### Why no entitlements

`scripts/SpektraFilm.entitlements` is an intentionally **empty** plist. The
hardened runtime only requires entitlements for capabilities that gate code
execution or sandbox access, and the app uses none: no `dlopen`, no JIT, no
plugins (the `NSBundle` calls look up the bundled `.metallib`, they do not load
code), not sandboxed, single binary. The reasoning is recorded in that file —
add to it if a future change introduces plugin loading, JIT, or a helper binary.

### Don't trust `spctl` locally

With Gatekeeper assessments disabled, `spctl -a` prints `accepted` with
`override=security disabled` and has **not assessed anything**. Check
`spctl --status` before believing a local pass. The script warns when it sees
this; confirm the result on a clean Mac or with assessments enabled.

### Once notarized

Drop the "if macOS blocks it" block and the `xattr` command from the release
notes, and update `PRODUCTION_QA.md` §9 — "notarization, stapling, and Gatekeeper
assessment succeed" becomes checkable rather than aspirational.