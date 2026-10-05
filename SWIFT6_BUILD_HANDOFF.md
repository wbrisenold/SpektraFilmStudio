# SpektraFilm v0.6.0 — Swift 6.2 Build Handoff

Exact pinned build: app commit `c3a1030e52083d5865f05f9165cfb3702e4d303f`,
native core commit `8f6651858f439a99b7202b4b8dea59e344dadf5d`.
Toolchain used: macOS 15.7.9, Swift 6.2.4, `x86_64`, Command Line Tools only
(no full Xcode installed).

Run everything through `./BUILD_EXACT_GITHUB_V0.6.command`. Do not hand-edit the
checkout: the script resets it to the pinned commit on every run and re-applies
`v0.6.0-swift6-fixes.patch`. Local edits that are not in that patch are silently
destroyed.

## Why this file exists

The v0.6.0 tag shipped in early 2026 and does not compile on a Swift 6.2
toolchain. It compiled on the Xcode 26 / macOS 26 SDK the author used, so the
breakage only appears on machines that are otherwise fully supported. Five
distinct problems had to be fixed, plus three latent bugs that the repo's own QA
script was already designed to catch but had itself drifted out of date.

The fixes live in `v0.6.0-swift6-fixes.patch` and are applied automatically.
This document records *why* each one exists so nobody re-derives it or
"simplifies" it back out.

## 1. Local edits were being destroyed by the build script

**Symptom:** fixes were applied, verified to compile, then vanished on the next
builder run. Source showed as pristine even though compilation had previously
passed with it patched.

**Cause:** `BUILD_EXACT_GITHUB_V0.6.command` runs
`git reset --hard <commit>` before building. Anything not committed or otherwise
re-applied is lost. This cost several cycles of "re-apply, verify, run builder,
discover it is gone."

**Fix:** the four Swift fixes are stored as a patch file and applied with
`git apply` immediately after the reset. The script also asserts the checkout is
clean *before* applying, and afterwards that the only modified files are the six
expected ones — so an unexpected local edit fails loudly instead of being
destroyed.

## 2. `rtk git diff` does not produce an applicable patch

**Symptom:** `error: No valid patches in input (allow with "--allow-empty")`
followed by `ERROR: Swift 6 fix patch does not apply`.

**Cause:** `rtk git diff` emits a condensed, stat-style summary for the model to
read, not a unified diff. The generated "patch" had ~644 bytes and no `diff
--git` / `@@` hunks, so `git apply` had nothing valid to parse. It is a display
wrapper, not a plumbing command.

**Fix:** generate patches with plain `git diff` (or
`git diff --binary > patch`). Never redirect `rtk` output to a file that another
tool must parse. Always confirm with
`git apply --check <patch>` before relying on a patch file.

## 3. Nested `async` function lost `@MainActor` inside a `Task`

**File:** `Sources/SpektraFilmFast/AppModel.swift`
**Error:** `actor-isolated property 'filmOutput' can not be referenced from a
Sendable closure` / calls to main-actor state escaping into a non-isolated
context.

`sample(mired:tint:)` is declared `async` inside a `Task { }` body in a
`@MainActor` type. Being `async` does **not** inherit the enclosing actor
isolation — an `async` function is *nonisolated* by default, so it silently left
the main actor and could not touch `filmOutput` or other main-actor state.

**Fix:** mark it explicitly:

```swift
@MainActor func sample(mired: Double, tint: Double) async throws -> (Double, StudioAnalysisMetrics, RawSettings) {
```

The rule: **inside a `Task`, an `async` function does not inherit actor
isolation. Write `@MainActor` explicitly on every one.**

## 4. `??` cannot hold an `await` expression

**File:** `Sources/SpektraFilmFast/ManagedIngest.swift`
**Error:** `left side of nil coalescing operator '??' has non-optional type
'String', so the right side is never used` — and, once that was resolved,
`async call in an autoclosure that does not support concurrency`.

The original:

```swift
let sourceHash = expectedHash ?? (try await sha256(url: source))
```

The right-hand side of `??` is an `@autoclosure`, and autoclosures cannot be
`async`. This fails on any toolchain, not just Swift 6.

**Fix:** branch explicitly, hoisting the `await` out of the autoclosure:

```swift
let sourceHash: String
if let expectedHash { sourceHash = expectedHash } else { sourceHash = try await sha256(url: source) }
```

The rule: **`await` cannot live inside an autoclosure (`??`, `map`, `filter`,
`compactMap`, `assert`, and friends). Branch instead.**

## 5. `NSEvent` crossing an isolation boundary (non-Sendable)

**File:** `Sources/SpektraFilmFast/SpektraFilmFastApp.swift`

`addLocalMonitorForEvents` has a `NSEvent? -> NSEvent?` signature, but it is
invoked from a non-main thread while the body touched main-actor state. `NSEvent`
is not `Sendable`, so returning or passing it across the boundary is rejected
under Swift 6. The nested `applyRating` / `applyFlag` closures inside the
`MainActor.assumeIsolated` block also captured main-actor state without being
isolated themselves.

**Fix:** compute a `Bool` inside the isolated region and let the outer closure do
the non-isolated work, so `NSEvent` never crosses the boundary:

```swift
let handled: Bool = MainActor.assumeIsolated {
    guard let model else { return false }
    ...
    @MainActor func applyRating(_ value: Int) { ... }
    @MainActor func applyFlag(_ value: ProjectFlag) { ... }
    ...
    default: return false
}
return handled ? nil : event
```

Note every `return event` inside the isolated block became `return false` or
`return true`; the handler returns `nil` when it consumed the event.

The rule: **never return or pass a non-`Sendable` AppKit/Foundation object
through an isolation boundary. Return a `Bool` and convert outside.**

## 6. Mutated loop `var` captured by `@Sendable` closure

**File:** `Sources/SpektraFilmFast/AppModel.swift`

A `var job` is reassigned each iteration of a loop, and `job.settings` was read
inside a `Task.detached`. Capturing the mutable `var` in a `@Sendable` closure is
a data race and a Swift 6 error.

**Fix:** copy the needed values into `let` constants *before* the closure, then
capture only those:

```swift
let geometrySettings = item.look.geometry
let exportSettings = job.settings
let output = try await Task.detached(priority: .utility) {
    let geometryOutput = GeometryEngine.transformed(filmOutput, settings: geometrySettings)
    return try geometryOutput.resizedForExport(settings: exportSettings)
}.value
```

The rule: **a `@Sendable` closure may only capture immutable copies. Hoist
loop-mutated `var`s into `let`s first.**

## 7. Hard-clipping diagnostics were computed pre-conversion

**File:** `Sources/SpektraFilmFast/StudioAnalysis.swift`
**Found by:** `scripts/qa_production.py` pass 7.

This one was a genuine behavioural bug, not a toolchain issue. Clipping
indicators mixed two different buffers: `outputPeak`/`outputLuma` came from
`diagnosticBuffer` (final, display-referred pixels), but `isHardHighlight` and
`isHardShadow` were derived from `sourcePeak`, read from the linear `output`
buffer before display conversion. The hard-clip overlay therefore disagreed with
what the photographer actually saw.

The repo's own QA asserts the correct contract — hard clipping must be
final-output-only, and diagnostics must not inspect pre-film values. The source
violated it, so `verify_source.sh` failed before it ever reached compilation.

**Fix:** all four indicators now derive from the final output; the pre-conversion
`sourceR/G/B` reads were removed, along with the then-unused `x`, `y` and
`sourceIndex` bindings in that loop.

## 8. `SOURCE_MANIFEST.sha256` must be regenerated after any source edit

`verify_source.sh` compares a `find`-derived file list against the manifest and
then verifies every SHA-256. Any edit to a covered file fails the gate until the
manifest is regenerated — by design, so silent source drift is impossible. This
is also why problem 7 surfaced as a confusing "does not cover the complete
source package" message rather than as the analysis bug it really was.

Regenerate with:

```bash
find . -type f -not -path './.build/*' -not -path './dist/*' \
  -not -path './.git/*' -not -name 'SOURCE_MANIFEST.sha256' -print \
  | sed 's#^./##' | LC_ALL=C sort \
  | while IFS= read -r f; do shasum -a 256 "$f"; done > SOURCE_MANIFEST.sha256
```

`v0.6.0-swift6-fixes.patch` includes the updated manifest, so a normal builder
run needs no manual step.

## 9. QA script itself had drifted out of date (two assertions)

`scripts/qa_production.py` failed on its own pinned commit — the checks were
written against an older revision of the code.

- **Pass 7** asserted the literal `let outputPeak = max(outRRaw`, but the real
  expression is `let outputPeak = max(outR, max(outG, outB))`. Updated to the
  actual text. (The assertion's *intent* is preserved and is now genuinely
  enforced via problem 7.)
- **Vectorscope check** asserted a hardcoded `"123.0"` skin reference angle.
  The angle is now *derived* from a reference swatch in `SkinToneReference.swift`
  (it computes to 124.024°), and `ScopeEngine` correctly consumes the shared
  constant. Replaced with assertions that the shared derived constant exists and
  is used — which is the real contract and is stricter than the old literal check,
  since a hardcoded angle drifting from the swatch is exactly the bug that
  motivated the change.

## Verification performed

```bash
./BUILD_EXACT_GITHUB_V0.6.command
```

- `verify_source.sh` passed: whole-target type-check, manifest, shell syntax,
  resource hashes, and the full QA suite (warnings only, no errors).
- `swift build -c release` succeeded; native core built from the pinned commit.
- App bundle passes `codesign --verify --deep --strict` and is ad-hoc signed.
- Binary is Mach-O 64-bit `x86_64`, matching the Intel-only target.
- Launched successfully; process stays resident with no crash reports.

Known-harmless remaining warnings (from upstream, not touched): explicit
`self` capture suggestions in `AppModel.swift` task groups, and a `var job` in
`ManagedIngest.swift` that is never mutated.

## Build outputs

- App: `SpektraFilmFast-v0.6.0-pinned/dist/SpektraFilm.app`
- ZIP: `SpektraFilmFast-v0.6.0-pinned/dist/SpektraFilm-0.6.0-macOS-intel.zip`
- Log: `build.log`

## Do not do these

- Do not hand-edit `SpektraFilmFast-v0.6.0-pinned/` — the reset will erase it.
  Put the change in `v0.6.0-swift6-fixes.patch` and add any new path to
  `PATCHED_FILES` in the builder script.
- Do not generate patch files by redirecting `rtk` output.
- Do not skip `scripts/verify_source.sh`. It catches cross-file type errors that
  a single-file parse cannot, and it is what surfaced problem 7.
- Do not regenerate `SOURCE_MANIFEST.sha256` before understanding *why* the gate
  failed — a manifest error is often the visible symptom of a real source bug.