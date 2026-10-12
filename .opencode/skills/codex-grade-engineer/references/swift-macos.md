# Swift / SwiftUI / macOS / image-processing verification guide

## Version and toolchain reality

1. Inspect `Package.swift`, Xcode project build settings (`MACOSX_DEPLOYMENT_TARGET`, Swift language version), target platform, Swift compiler, Xcode version, and architecture. `swift --version` is compiler version, NOT the Swift language mode and NOT the minimum macOS deployment target.
2. Check **every newly used API** for its real minimum macOS/iOS availability, including SwiftUI modifiers, AppKit classes and Core Image/Metal features. `#available` only helps if an actual compatible alternate behavior is implemented where needed.
3. Xcode on CI may be much newer than the oldest supported Intel macOS. A successful newer SDK build cannot establish Catalina 10.15 runtime correctness. Build and smoke-test on the oldest supported OS when accessible.
4. Inspect SwiftPM resolution and project schemes. Don't make up scheme names, package products, or build artifacts. Use the existing CI workflow as an additional source of truth.
5. `sourcekit-lsp` supplies diagnostics and symbol navigation when installed/configured and indexed; it is not a substitute for a compiler build. OpenCode's LSP integration is optional and may be disabled. Ask for or install missing tools only with appropriate user authorization.

## Swift correctness checks

- Read the **declaration** and all usages before editing a function's parameter labels, generic constraints, actor isolation, or thrown errors.
- `try` / `try?` only for throwing calls. Avoid hiding errors with `try?` when diagnostics or recovery are needed.
- Verify `Binding` read/write ownership; ensure the actual user interaction mutates state once, triggers expected recalculation, and persists if required.
- Prefer typed results and explicit errors over magic defaults. Avoid force-unwrapping outlets/paths when legitimate nil states exist.
- Consider `@MainActor` for UI-bound state, cancellable tasks for repeated image updates, cooperative cancellation, `Sendable` correctness, and buffer/data lifetime. Never blanket-add unsafe concurrency annotations to silence the compiler.
- Prefer documented concurrency migration guidance; don't switch the whole project to Swift 6 mode to repair a local error. Avoid gratuitous compatibility changes.

## SwiftUI and AppKit

- Trace gesture/button/menu/slider -> Binding/Observable model -> compute -> published state -> visible UI. Verify both editing and commit events when present.
- Inspect view identity, `@State`, `@Binding`, `@ObservedObject`, `@StateObject`, `@Observable`, selection/focus, `.task` lifetime, and expensive work during `body` recomputation.
- Avoid extra full-image renders for every pointer tick. Cache keys must include all relevant image identity, color transform, params, and generation ID; stale asynchronous renders must never overwrite a newer edit.
- For UI bug fixes, include a behavioral test, screenshot/smoke test, or state an honest manual verification instruction when the UI can't run locally.
- Test error cases (missing access rights/bookmarks, expired security scopes, dismissed panels, canceled tasks, absent resources).

## Metal, Core Image, RAW and color pipelines

- Document actual execution path and devices: Swift/CPU orchestration often remains even when GPU computes kernels. Never promise literal zero CPU work without defining the scope.
- Verify pixel formats, coordinate conventions, alpha/premultiplication, floating point range, image orientation, color space/tag, LUT domains/shapers, ICC profiles, EOTF/OETF, and display versus scene-linear transformations. Preserve out-of-range sensor/highlight values until appropriate mapping stage.
- Test preview/export parity using the same source and adjustments at deterministic pixel coordinates; permit only justified tolerance/precision differences.
- Confirm masks, waveforms, histogram, clipping/false-color tools operate on the intended same image stage and are invalidated on relevant edits.
- Keep Core Image/Metal buffers alive until asynchronous GPU work is finished; use consistent texture usage flags, correct synchronization, and avoid unmeasured copies.
- Measure real latency, memory, cache hits and export cost before claiming performance improvements. Track p50 and slow cases on comparable images when performance is a goal.
- Correctly identify fallback paths; do not remove a CPU fallback if that breaks user-required hardware/OS support unless explicitly requested and tested.
- For claims of algorithm equivalence (AMaZE, filmic transforms, lens correction, etc.), require source/reference provenance, compatible license, numerical fixtures, and side-by-side image tests. A lookalike is not a 1:1 port.

## Fast verification commands

SwiftPM (if repository contains `Package.swift`):

```bash
swift --version
swift build
swift test
```

Xcode-based macOS app (use actual verified scheme and project):

```bash
xcodebuild -list -project YourApp.xcodeproj
xcodebuild -project YourApp.xcodeproj -scheme YourActualScheme -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

For tests, use an actual testable scheme and supported destination; an app-only scheme may have no tests. On a non-macOS machine, do not claim the above build ran. GitHub Actions logs establish CI outcomes only for the hosted runner, not a local Catalina runtime.

The bundled `scripts/verify-swift.sh` supports SwiftPM autodetection and explicit Xcode project/workspace scheme selection. Review `--help` before running. It avoids guessing arbitrary Xcode schemes.
