# BUILD_PITFALLS.md — hard-won build/release failures

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

# Swift 6.2 toolchain failures (cost a full v0.6.0 release rebuild)

The v0.6.0 tag shipped in early 2026 and **does not compile on Swift 6.2 / Xcode 26.**
It was authored against an older toolchain, so every one of these is invisible to
the author and fatal to a fresh clone on a current machine. Five separate defects,
plus three latent problems the repo's own QA had already been written to catch.

All five are now fixed in the source and **machine-checked by
`scripts/verify_source.sh`**, so a regression fails the gate instead of the release.

## 10. `async func` does NOT inherit `@MainActor` inside a `Task {}`

**Symptom:** `actor-isolated property 'filmOutput' can not be referenced from a
Sendable closure`, or main-actor state referenced from a non-isolated context, in
`AppModel.swift`.

**Cause:** `sample(mired:tint:)` is declared `async` inside a `Task { }` body in a
`@MainActor` type. Being `async` does **not** inherit the enclosing actor — an
`async` function is *nonisolated* by default, so it silently leaves the main actor.

**Fix:**

```swift
@MainActor func sample(mired: Double, tint: Double) async throws -> (Double, StudioAnalysisMetrics, RawSettings) {
```

**Rule:** inside a `Task`, write `@MainActor` on every `async` function explicitly.

**Guard:** `verify_source.sh` greps for `@MainActor func sample(mired:`.

## 11. `await` cannot live inside an autoclosure

**Symptom:** in `ManagedIngest.swift`, either
`left side of nil coalescing operator '??' has non-optional type 'String'` or
`async call in an autoclosure that does not support concurrency`.

**Cause:** the right side of `??` is an `@autoclosure`, and autoclosures cannot be
`async`. This breaks on *any* toolchain, not just Swift 6.

```swift
// WRONG
let sourceHash = expectedHash ?? (try await sha256(url: source))

// RIGHT
let sourceHash: String
if let expectedHash { sourceHash = expectedHash } else { sourceHash = try await sha256(url: source) }
```

**Rule:** `??`, `map`, `filter`, `compactMap`, `assert`, and friends are
autoclosures. Never put `await` inside one — branch instead.

**Guard:** rejects `?? (try await` anywhere in `ManagedIngest.swift`.

## 12. `NSEvent` is not `Sendable` — never let it cross an isolation boundary

**Symptom:** non-Sendable type crossing actor boundary, in `SpektraFilmFastApp.swift`.

**Cause:** `addLocalMonitorForEvents` is `(NSEvent?) -> NSEvent?` and is invoked off
the main thread, but its body touched main-actor state. Returning/passing `NSEvent`
across the boundary is rejected under Swift 6. The nested `applyRating`/`applyFlag`
closures also captured main-actor state without being isolated themselves.

**Fix:** compute a `Bool` inside the isolated region; convert outside it.

```swift
let handled: Bool = MainActor.assumeIsolated {
    guard let model else { return false }
    @MainActor func applyRating(_ value: Int) { ... }
    @MainActor func applyFlag(_ value: ProjectFlag) { ... }
    default: return false
}
return handled ? nil : event
```

Every `return event` inside the isolated block becomes `return true`/`false`; the
handler returns `nil` when it consumed the event.

**Rule:** never return or pass a non-`Sendable` AppKit/Foundation object through an
isolation boundary. Return a `Bool` and convert outside.

**Guard:** requires `let handled: Bool = MainActor.assumeIsolated` and
`return handled ? nil : event`.

## 13. A `@Sendable` closure cannot capture a loop-mutated `var`

**Symptom:** concurrency/data-race error on `job.settings` inside `Task.detached`
in `AppModel.swift`.

**Cause:** `var job` is reassigned each loop iteration, so capturing it in a
`@Sendable` closure is a data race.

**Fix:** hoist immutable copies before the closure.

```swift
let geometrySettings = item.look.geometry
let exportSettings = job.settings
let output = try await Task.detached(priority: .utility) {
    let geometryOutput = GeometryEngine.transformed(filmOutput, settings: geometrySettings)
    return try geometryOutput.resizedForExport(settings: exportSettings)
}.value
```

**Rule:** a `@Sendable` closure may only capture immutable copies.

**Guard:** rejects `resizedForExport(settings: job.settings)`.

## 14. Hard-clip diagnostics were computed pre-conversion ← real bug, not toolchain

**Symptom:** `verify_source.sh` failed at `scripts/qa_production.py` pass 7 with
`final-output highlight analysis missing`.

**Cause:** in `StudioAnalysis.swift`, `outputPeak`/`outputLuma` came from
`diagnosticBuffer` (final, display-referred), but `isHardHighlight` and
`isHardShadow` were derived from `sourcePeak`, read from the linear `output`
buffer before display conversion. The hard-clip overlay therefore disagreed with
what the photographer actually saw.

The repo's own QA asserts the correct contract — hard clipping must be
final-output-only — so the source was wrong and QA was right. **When this gate
fails, check whether the source or the assertion is wrong before editing either.**

**Fix:** all four indicators derive from the final output; the pre-conversion
`sourceR/G/B` reads and the then-dead `x`/`y`/`sourceIndex` bindings were removed.

**Guard:** rejects `sourcePeak` in `StudioAnalysis.swift`.

## 15. `SOURCE_MANIFEST.sha256` must be regenerated after any source edit

`verify_source.sh` diffs a `find` file list against the manifest and verifies every
SHA-256, so any edit fails the gate until it is regenerated. This is why pitfall 14
surfaced as a confusing *"does not cover the complete source package"* instead of
the analysis bug it really was.

```bash
find . -type f -not -path './.build/*' -not -path './dist/*' \
  -not -path './.git/*' -not -name 'SOURCE_MANIFEST.sha256' \
  -not -name '.DS_Store' \
  -not -path './.batch-edit-backup-*' -print | sed 's#^./##' | LC_ALL=C sort \
  | while IFS= read -r f; do shasum -a 256 "$f"; done > SOURCE_MANIFEST.sha256
```

`find` must also skip OS artifacts. The upstream manifest pinned a hash for
`.DS_Store`, which is **gitignored and untracked** — so the build depended on an
unstable OS file that Finder rewrites at will. `verify_source.sh` now excludes
`.DS_Store` from both the find and the coverage comparison.

**Rule:** a manifest error is often a *symptom* of a real source bug. Understand
why the gate failed before regenerating.

## 16. QA script assertions had drifted out of date (two, on the pinned commit)

`scripts/qa_production.py` failed on its own commit — written against older code:

- pass 7 asserted the literal `let outputPeak = max(outRRaw`; the real expression is
  `let outputPeak = max(outR, max(outG, outB))`. Updated to the actual text.
- the vectorscope check asserted a hardcoded `"123.0"` skin reference angle. That
  angle is now **derived** in `SkinToneReference.swift` from a reference swatch
  (`position(displayR: 1.0, displayG: 200/255, displayB: 160/255).angleDegrees`,
  which computes to 124.024°), and `ScopeEngine` correctly consumes the shared
  constant. Replaced with assertions that the derived constant exists and is used —
  **stricter** than the old literal check, because a hardcoded angle drifting from
  its reference swatch is exactly the bug that motivated the change.

**Rule:** prefer asserting *behavior/structure* over magic literals. A literal
assertion encodes one revision's incidental text and breaks on any refactor.

## 17. `git reset --hard` in the build wrapper silently destroys local fixes

**Symptom:** fixes applied, verified to compile, then gone on the next builder run —
the tree showed as pristine.

**Cause:** the wrapper resets the checkout to the pinned commit before building.
Anything not committed is erased, which caused several wasted
"re-apply → verify → run builder → it's gone" cycles.

**Fix:** the fixes live in a patch file applied immediately after the reset, and the
wrapper asserts the checkout is clean before applying and that only the six expected
files differ afterwards.

**Rule:** in any repo whose build script resets the tree, local fixes must live in
an applied patch (or a commit), never in working-copy edits.

## 18. A summary-style `git diff` produces an unapplicable patch

**Symptom:** `error: No valid patches in input (allow with "--allow-empty")`,
reported as `ERROR: Swift 6 fix patch does not apply`.

**Cause:** the patch had been generated by a *display wrapper* that emits a
condensed stat table (`file | 10 +++---`) instead of a unified diff. `git apply`
had no `diff --git`/`@@` hunks to parse, so the error blamed the patch target while
the real fault was the generator.

**Fix:** generate patches with plain `git diff > file.patch`, and verify with
`git apply --check` before relying on one. The wrapper now hard-fails early with an
explicit message if the patch has no `diff --git` headers.

**Rule:** never redirect a summarizing tool's output to a file another tool parses.

---

## 19. An installer that ships an *installer* gets reported as "the update didn't take"

**Symptom:** user receives a patch ZIP, the agent applies it, rebuilds, re-zips, and
pushes. The user launches the app and says **"it still looks the same."** Multiple
build cycles followed, all producing a bit-identical-looking UI.

**Cause:** the archive being handed around was itself an *installer*, not source or
a built app. Applying it planned changes but the UI source files were never actually
present in the checkout. Proof:

```bash
for f in StudioUI StudioOmniSearch RedlampPortedUI; do
  [ -f "Sources/SpektraFilmFast/$f.swift" ] && echo "PRESENT $f" || echo "MISSING $f"
done
```

All `MISSING` — yet the agent had already rebuilt and re-shipped twice.

**Fix:** run the package's own install command (`APPLY_BUILD_VERIFY.command`, not a
hand-rolled `git apply`), then prove provenance before reporting success:

```bash
python3 <pkg>/VERIFY.py "$PWD" --app "$PWD/dist/SpektraFilmStudio.app"
```

`VERIFY.py` compares the bundle's embedded `SpektraSourceCommit` against `git rev-parse
HEAD`. **If that check is skipped, "build succeeded" only proves the compiler ran.**

**Rule:** never report a patch as applied until a *file-existence* check confirms the
patched files are on disk AND the built artifact's embedded commit matches HEAD.
Rebuilding an unchanged tree reproduces the same app; that is not a fix.

## 20. Cross-stage anchors inside one patch package drift out of sync

**Symptom:** the package's own guard aborts with
`omni overlay: expected one anchor, got 0; refusing patch` — on a checkout the
package was explicitly written against.

**Cause:** two stages in the *same* package edited the same line inconsistently.
`apply_studio_design.py:233` widens the minimum window
`.frame(minWidth: 1024, ...)` → `1080`; the later `apply_glass_omni_scene.py:140`
anchored on the literal `1024` and therefore matched nothing. The guard was behaving
correctly — it refused to guess.

**Fix:** match the anchor structurally, not by literal value, so stage order stops
mattering:

```python
m = re.search(r'^        \.frame\(minWidth: (\d+), minHeight: (\d+)\)$', s, re.M)
if m is None:
    raise RuntimeError('omni overlay: expected one .frame(minWidth:minHeight:) anchor')
frame = m.group(0)   # reuse whatever width the previous stage chose
```

**Rule:** in a multi-stage patch package, an earlier stage's literal output is an
*input*, not a constant. Anchor on structure. Any stage whose anchors are invalidated
by a sibling stage in the same package is an ordering bug, not repo drift — check
`grep -rn '1024\|1080' <package>/baseline/*.py` before blaming the checkout.

## 21. A vendored third-party license file fails your own whitespace gate

**Symptom:** install aborts at the commit step with
`git diff --cached --check exited 2: THIRD_PARTY/.../LICENSE-MPL-2.0.txt:38: trailing whitespace`.

**Cause:** the upstream MPL-2.0 text carries one trailing space on a wrapped line.
`git diff --check` runs **before** commit, so the gate fires on a file nobody edited
by hand.

**Fix:** strip trailing whitespace in the *vendored copy* inside the patch package.
Never weaken `git diff --check` — it is doing its job, and the exemption would
silently permit real whitespace damage in first-party code.

**Rule:** gates fail on vendored third-party text. Normalize the vendored file, keep
the gate strict.

## 22. Manifest conflict markers survive into a pushed release

**Symptom:** `verify_source.sh` keeps reporting *"SOURCE_MANIFEST.sha256 does not
cover the complete source package"* with no obvious source error. `wc -l` on the
manifest is far larger than the file count of the repo.

**Cause:** a `git stash pop` conflicted in `SOURCE_MANIFEST.sha256`; it was resolved by
copying `git show HEAD:SOURCE_MANIFEST.sha256` over it — but **that HEAD version was
itself already committed with unresolved `<<<<<<< Updated upstream` /
`>>>>>>> Stashed changes` blocks**. Restoring it restored a corrupt file, and the
corruption was committed and pushed.

**Detect it directly** (do not trust the generic gate message):

```bash
grep -c '<<<<<<<\|>>>>>>>' SOURCE_MANIFEST.sha256   # must be 0
```

**Fix:** regenerate from scratch using the §15 command. A manifest is a *derived
artifact* — never merge one, always regenerate it.

**Rule:** after any stash/pop/merge that touches a source file, grep for conflict
markers before committing. A "resolved" file that still contains markers passes
`git status` (it looks modified, not conflicted) and ships.

## 23. A build guard can refuse on disk space while the real problem is stale build dirs

**Symptom:** `scripts/build_app.sh` aborts with
`Not enough free disk space for a safe release build: 1 GB free, 8 GB required.`

**Cause:** `.build/` and `dist/` from previous runs consumed the space the build
needed. The guard was correct; the remedy is cleanup, not lowering the threshold.

**Fix:**

```bash
rm -rf .build dist          # regenerated by the next build
# only if genuinely constrained:
SPEKTRAFILM_MIN_FREE_GB=4 bash scripts/build_app.sh
```

**Rule:** clear `.build` and `dist` before a release build. Lowering the free-space
guard is a last resort and should be stated explicitly, because it removes a real
safety check (see the guard message itself — it tells you this).

## 24. Verify the whole chain, not just the step you changed

**Symptom:** a rebuild was reported as successful, yet the user still saw the old UI.

**Rule:** a patch update is only finished when all four of these agree:

| Check | Command | Catches |
|---|---|---|
| Files on disk | file-existence probe (pitfall 19) | patch never applied |
| Source gates | `./scripts/verify_source.sh` | source regression |
| Build identity | `VERIFY.py` / embedded commit vs HEAD | stale binary re-zipped |
| Runtime | `--ux-smoke-test`, `--self-test` | code compiles but misbehaves |

A green build log only proves the **compiler** ran. Report success from the *identity*
check plus the smoke tests, and show the user screenshots so visual claims are checked
by eye — that is what finally confirmed this UI stage.

---

## Release checklist

1. Run `swiftc -frontend -parse Sources/SpektraFilmFast/*.swift`, `swift package dump-package`, `python3 scripts/qa_production.py`, `./scripts/qa_10_passes.sh`, and `./scripts/verify_source.sh`.
2. Confirm `VERSION` matches the intended release.
3. On a Mac with Xcode 26 / macOS 26 SDK, run `BUILD_ON_MAC.command`.
4. Verify `lipo -archs` contains `x86_64 arm64`, app version matches, bundled renderer resources exist, and the pinned native core commit is recorded.
5. Run Metal `--self-test` and `--studio-soak-test`.
6. For public distribution, perform Developer ID hardened-runtime signing, notarization, stapling, and Gatekeeper assessment.
7. Verify the produced ZIP and checksum independently before publishing.
8. **Confirm the artifact was built from the intended commit** — compare the bundle's
   embedded source commit against `git rev-parse HEAD` (pitfall 24). This is the check
   that distinguishes a real update from a re-zipped old app.
9. Confirm `grep -c '<<<<<<<' SOURCE_MANIFEST.sha256` returns `0` (pitfall 22).

## Known open item

The remaining major preview optimization is a direct Metal-backed viewer surface to remove the CPU float-buffer → `CGImage` display handoff. Do not describe that optimization as complete until it is implemented and measured on macOS.
