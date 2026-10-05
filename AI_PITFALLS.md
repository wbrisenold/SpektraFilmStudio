# AI_PITFALLS.md — hard-won build/release failures

Read this before touching CI, `scripts/build_app.sh`, or the release workflow. Every
item below cost a real red build. Four are latent bugs that were present since the
source was authored; two are my own mistakes while debugging.

Verified working state: release `v0.1.0` (2026-10-02), run 37031948261, all steps green.

---

## 1. The build workflow is `ci.yml`, not `build.yml`

This local-build package intentionally does not ship GitHub Actions workflows. The build gate is `BUILD_ON_MAC.command` on Xcode 26 / the macOS 26 SDK. Historical workflow-specific notes below are retained only as prior troubleshooting context.

## 2. `macos-15` cannot compile the pinned native core

**Symptom:** run fails compiling the upstream core with
`queryTimestampFrequency` / "use of undeclared identifier", or a wall of
`no known instance of member`.

**Cause:** `scripts/bootstrap_native.sh` pins upstream at
`8f6651858f439a99b7202b4b8dea59e344dadf5d`, which calls
`-[MTLDevice queryTimestampFrequency]`. That selector is declared only in the
macOS 26 SDK. The upstream call carries an `@available(macOS 26.0, *)` guard,
but availability guards are a *runtime* check and do not satisfy *compile-time*
selector resolution.

**Fix:** `runs-on: macos-26` in both workflows. Do not "fix" this by unpinning
upstream — the handoff forbids that without a parity pass.

**Related trap:** `dctlw`/`swiftc` on an older local CLT will reproduce this even
when the workflow is correct. Check `swift --version` and the SDK before blaming
the workflow.

## 3. `source-checks` passing does NOT mean the code builds

`scripts/verify_source.sh` runs `swiftc -frontend -parse` — **parse only**. It
catches no type errors, so it goes green on code that cannot compile. It also
`bash -n`s the shell scripts (syntax only, no execution).

**Never treat a green `source-checks` as evidence of buildability.** Only
the local Intel x86_64 release build proves that.

## 4. `Package.swift` is `swift-tools-version: 6.0` → Swift 6 strict concurrency

Two errors block the release build. Both are fixed in `e79c081`.

**a. `BridgeCatalog`** — shared mutable singleton, Sendable violation.

Use `@unchecked Sendable` on the class.

**Wrong fix, already tried and reverted:** `@MainActor`. It cascades into
`RenderLook.defaults` / `ProjectImageRecord` and drops a required `Sendable`
conformance, which is a *larger* error than the one it fixed.

**b. `NativeRenderer.handle`** — accessing actor-isolated stored property from
`deinit`.

Use `nonisolated(unsafe)` on the `let`. It is immutable and never mutated, which
is exactly the precondition the attribute requires.

## 5. `$(build_swift_arch …)` silently poisons the binary path ← the nasty one

**Symptom:** build fails *after* `Build complete!`, with a message that looks
like a filesystem problem:

```
/…/.build/swift-arm64/arm64-apple-macosx/release/SpektraFilmFast (File name too long)
```

The path is not too long. The error is a lie.

**Cause:** `scripts/build_app.sh` captures the function's stdout:

```bash
BIN_ARM64="$(build_swift_arch arm64)"
```

`swift build` writes `Building for production...` and `Build complete!` to
**stdout**. So `BIN_ARM64` became a multi-line blob ending in the real path, and
`lipo -create` was handed that blob instead of a path. `lipo` failed and printed
the last token with an errno appended.

**Fix:** redirect swift's output to stderr, leaving stdout to carry only the path:

```bash
swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH" >&2
```

**Rule:** any function invoked via `$(...)` must write only its return value to
stdout. Verbose/diagnostic output goes to stderr.

**Why this cost hours:** every isolated test passed — `swift build` alone exited
0, `find` returned a valid path, `lipo -archs` reported `arm64`. Only the full
script reproduced it, because only the full script combined the command
substitution with the build.

## 6. Runner is bash 3.2 — empty array + `set -u` is a fatal error

**Symptom:** `Publish GitHub Release` fails immediately:

```
/tmp/….sh: line 15: EXTRA[@]: unbound variable
```

**Cause:** `EXTRA=()` in `release.yml` is only populated for prereleases. Under
`set -euo pipefail` on bash 3.2 (which is what `/bin/bash` is on macOS runners),
expanding an empty array as `"${EXTRA[@]}"` is fatal. **Every stable release
would have failed here, permanently** — not specific to 0.1.0.

**Fix:** use the bash 3.2-safe form (commit `026c780`):

```bash
"${EXTRA[@]+"${EXTRA[@]}"}"
```

Verify against real bash 3.2 before trusting a shell idiom — `/bin/bash -c 'set -u;
a=(); echo "${a[@]}"'` exits 1 on this machine.

Note `scripts/verify_source.sh` has the same `set -euo pipefail` + `/bin/bash`
combination; the same trap applies to anything added there.

## 7. A failed release run leaves a tag that blocks the retry

`release.yml` creates/pushes tag `v$VERSION` **before** publishing. If publishing
fails, the tag survives, pinned to the pre-fix commit.

On re-run, the guard at `Ensure release tag exists for manual runs` refuses:

```
Refusing to reuse v0.1.0: it points to <old sha>, not this workflow commit <new sha>.
```

**Fix:** after pushing a fix, delete the stale tag so the workflow recreates it:

```bash
git push origin --delete refs/tags/v0.1.0 && git tag -d v0.1.0
```

Safe when no Release exists yet — nothing is lost.

**Trap:** `git ls-remote origin refs/tags/v0.1.0` returns the **annotated tag
object** SHA, not the commit. Compare the peeled ref:

```bash
git ls-remote origin 'refs/tags/v0.1.0*'   # 2nd line = refs/tags/v0.1.0^{} = commit
git rev-list -n1 v0.1.0                      # same commit
```

Deleting the wrong SHA on the basis of the first command alone moves your tag.

## 8. Historical GitHub workflow notes are not part of the current release path

Older iterations used GitHub Actions for Universal packaging; the current release is Intel x86_64 only. The current package intentionally uses `BUILD_ON_MAC.command` as the authoritative compile/link/runtime gate. Do not restore token-permission or `gh workflow run` steps unless the project explicitly returns to a hosted release workflow.

## 9. Debug-tracing scripts must live in `scripts/`

`build_app.sh` derives its root from its own location, so temporary trace copies must remain under `scripts/`. Run local source gates first, then use `BUILD_ON_MAC.command` on macOS.

---

## Release checklist

1. Run `swiftc -frontend -parse Sources/SpektraFilmFast/*.swift`, `swift package dump-package`, `python3 scripts/qa_production.py`, `./scripts/qa_10_passes.sh`, and `./scripts/verify_source.sh`.
2. Confirm `VERSION` matches the intended release.
3. On a Mac with Xcode 26 / macOS 26 SDK, run `BUILD_ON_MAC.command`.
4. Verify `lipo -archs` contains `x86_64 arm64`, app version matches, bundled renderer resources exist, and the pinned native core commit is recorded.
5. Run Metal `--self-test` and `--studio-soak-test`.
6. For public distribution, perform Developer ID hardened-runtime signing, notarization, stapling, and Gatekeeper assessment.
7. Verify the produced ZIP and checksum independently before publishing.

## Known open item

The remaining major preview optimization is a direct Metal-backed viewer surface to remove the CPU float-buffer → `CGImage` display handoff. Do not describe that optimization as complete until it is implemented and measured on macOS.
