# SpektraFilmStudio Performance Code Review

**Date**: October 14, 2026  
**Scope**: Entire application (not just recent changes)  
**Reviewer**: Buffy (Codebuff agent)  

---

## Executive Summary

The SpektraFilmStudio codebase demonstrates **strong performance engineering** across most areas. The architecture correctly prioritizes:
- Latest-wins scheduling for UI responsiveness
- Multi-layer caching (memory + disk) for expensive operations
- GPU acceleration for image processing
- Actor isolation for thread safety without blocking

However, several **moderate to high-impact performance issues** were identified that could cause perceptible lag, memory pressure, or wasted CPU cycles.

---

## Critical Issues (High Impact)

### 1. `CullEngine.facetColorHarmony` - O(n×52k) per image

**Location**: `Sources/SpektraFilmFast/CullEngine.swift:92-142`  
**Severity**: High  
**Issue**: The color harmony calculation iterates every pixel and for each pixel creates a 180×256 histogram bin lookup. For a 1080p thumbnail (~2M pixels), this is ~2M iterations with floating-point HSV conversion.

```swift
// Current: iterates ALL pixels
for py in 0..<height {
    for px in 0..<width {
        // ... HSV conversion + histogram update
    }
}
```

**Recommendation**: Subsample to ~1MP max (similar to `imageMetrics` which uses a step parameter). Color harmony at thumbnail scale doesn't need full resolution.

---

### 2. `CullEngine.facetDynamicRange` - Full sort of all pixels

**Location**: `Sources/SpektraFilmFast/CullEngine.swift:144-154`  
**Severity**: High  
**Issue**: Sorting all pixel luminances to find percentiles is O(n log n). For a 1080p image this is sorting ~2M values.

```swift
let sorted = luma.sorted()  // O(n log n) on FULL resolution
let p2 = percentile(sorted, p: 0.02)
let p98 = percentile(sorted, p: 0.98)
```

**Recommendation**: Use a histogram-based percentile (like `AutoContrastMath.bounds` does with 16384 bins) or reservoir sampling. This would reduce to O(n) with small constant.

---

### 3. `CullEngine.facetNoiseEstimate` - O(n) with 3×3 kernel

**Location**: `Sources/SpektraFilmFast/CullEngine.swift:156-185`  
**Severity**: Medium-High  
**Issue**: Immerkaer noise estimation iterates every interior pixel with a 3×3 kernel. Combined with the other metrics, this means multiple full-image passes.

**Recommendation**: Share the luma array across metrics (already built in `facetSupplementaryMetrics`) and subsample for noise estimation. Noise at thumbnail scale is adequately estimated at 1/4 resolution.

---

### 4. Multiple full-pass metrics in `facetSupplementaryMetrics`

**Location**: `Sources/SpektraFilmFast/CullEngine.swift:360-383`  
**Severity**: Medium  
**Issue**: This function builds a luma array once, then calls four separate O(n) functions. While the luma reuse is good, each function still iterates the full array.

**Recommendation**: Compute all four metrics in a single pass over the luma array. This reduces cache misses and improves memory bandwidth utilization.

---

## Moderate Issues

### 5. `CullEngine.imageMetrics` - Step-based subsampling is good, but...

**Location**: `Sources/SpektraFilmFast/CullEngine.swift:307-381`  
**Severity**: Low-Medium  
**Observation**: The step-based sampling targeting ~420 pixels is well-designed. However, the inner loop recomputes `luma()` which bounds-checks every access.

```swift
// luma() does bounds checking on every call
private static func luma(_ payload: ThumbnailPayload, _ x: Int, _ y: Int) -> Double {
    let ix = max(0, min(payload.width - 1, x))  // clamping every access
    let iy = max(0, min(payload.height - 1, y))
    // ...
}
```

**Recommendation**: Since the loop already ensures bounds, inline the luma calculation without clamping in the hot path.

---

### 6. `AppModel.visibleImages` - Full library scan on every filter change

**Location**: `Sources/SpektraFilmFast/AppModel.swift:476-532`  
**Severity**: Medium  
**Issue**: The `visibleImages` computed property filters and sorts the entire image array on every access. With 5000+ images and complex filters (smart collections, people groups), this can cause UI lag.

```swift
var visibleImages: [ProjectImageRecord] {
    let query = librarySearch.trimmingCharacters(...).lowercased()
    var values = project.images.filter { image in
        // Multiple condition checks per image
    }
    // Sort the entire filtered array
    switch project.sortMode { ... }
    return values
}
```

**Recommendation**: 
- Debounce filter changes (300ms threshold)
- Cache results when filters haven't changed
- Consider incremental updates for sort-only changes

---

### 7. `AppModel.matchesLibrarySearch` - Lowercase every comparison

**Location**: `Sources/SpektraFilmFast/AppModel.swift:534-551`  
**Severity**: Low  
**Issue**: Every search comparison lowercases both the query and the field. For a library with 5000 images and 8 searchable fields, that's 40,000 lowercasing operations per search.

**Recommendation**: Pre-lowercase fields when metadata is loaded, not during search. The metadata is already cached; the lowercase transform could happen once at ingest.

---

### 8. `GPUHostGradeEngine.apply` - `waitUntilCompleted()` blocks thread

**Location**: `Sources/SpektraFilmFast/GPUHostGradeEngine.swift:158`  
**Severity**: Medium  
**Issue**: The CPU fallback path calls `command.waitUntilCompleted()` which blocks the calling thread until GPU work finishes.

```swift
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()  // Blocks!
```

**Context**: This is only used in the CPU PixelBufferF32 path, not the GPU-only Metal path (which is correct). But for large images on slower GPUs, this could cause UI stalls.

**Recommendation**: Ensure this path is only used when the GPU path is genuinely unavailable, and consider yielding with `Task.yield()` if called from an actor with other work.

---

### 9. `NativeRenderer.render` - Heap allocation per render

**Location**: `Sources/SpektraFilmFast/NativeRenderer.swift:195-230`  
**Severity**: Low-Medium  
**Issue**: Every render allocates a new `[Float]` array for output:

```swift
var outputPixels = [Float](repeating: 0, count: input.width * input.height * 4)
```

For a 4K image, this is 256MB allocated and zeroed on every render.

**Context**: This is unavoidable for the CPU render path, but the comment explains the rationale (avoiding CoW copies). Consider pooling buffers if renders are frequent.

---

### 10. `ImageDecoder.sourceImage` - CIRAWFilter configuration per decode

**Location**: `Sources/SpektraFilmFast/ImageDecoder.swift:371-429`  
**Severity**: Low  
**Observation**: The raw filter is configured with raw settings on every decode. While necessary, some settings like `linearSpaceFilter` (CIToneCurve) are recreated from scratch.

```swift
if !identityCurve, let curveFilter = CIFilter(name: "CIToneCurve") {
    // Configure 5 control points
    rawFilter.linearSpaceFilter = curveFilter
}
```

**Recommendation**: Cache the CIToneCurve filter when the curve hasn't changed. CIFilter creation has non-trivial overhead.

---

## Cache Architecture Assessment

### Strengths

1. **Multi-tier caching** (AppModel → ImageDecoder → ThumbnailPipeline) is well-designed
2. **Memory pressure handling** is correctly implemented with tiered responses
3. **Generation counters** prevent stale-async-work bugs (correctly used throughout)
4. **In-flight deduplication** prevents redundant work (ImageDecoder, ThumbnailPipeline)
5. **LRU eviction** with byte tracking is correctly implemented

### Areas for Improvement

1. **`renderedFrameCache` in AppModel** (line ~590) uses a simple Dictionary + order array. The `touch()` operation does `removeAll { }` + `append` which is O(n). For a cache with hundreds of entries accessed during rapid preview updates, consider a true LRU data structure.

2. **Disk cache pruning** in ThumbnailPipeline scans the entire directory on every write when over budget. Consider deferred/prorated pruning.

---

## Memory Management

### Strengths
- `PixelBufferF32` uses value semantics correctly
- `withUnsafeBytes` used appropriately to avoid CoW copies
- Actor isolation prevents data races without excessive locking

### Concerns

1. **` PixelBufferF32` arrays are not pooled**: Every resize, grade, or export creates new arrays. For batch export of 100 photos at 24MP, this is significant allocation pressure. Consider an object pool for temporary buffers.

2. **`CGImage` creation in `makeCGImage8/16`**: These create new `Data` objects from pixel arrays. For preview thumbnail generation, this is acceptable, but for the export path, consider writing directly to file.

---

## Concurrency Model

### Strengths
- Actor-based isolation (`NativeRenderer`, `ImageDecoder`, `CullEngine`, etc.) is correct
- Task cancellation is checked at appropriate points
- Generation counters prevent race conditions
- `nonisolated(unsafe)` used judiciously with documentation

### Concerns

1. **`GPUHostGradeEngine.shared` is a shared singleton with an NSLock**: This breaks the actor-based isolation pattern. Consider making it an actor or ensuring it's only called from one concurrency domain.

2. **Some `Task.detached` calls could use structured concurrency**: In `ImageDecoder.decode()`, the `Task.detached` for the actual decode is appropriate (it's truly independent work). But in several places, `Task.detached` is used where a child task would suffice and provide better cancellation propagation.

---

## Metal/GPU Usage

### Strengths
- Correct use of `storageModePrivate` for GPU-only textures
- Texture pooling in `GPULiveDevice` reduces allocation overhead
- Command buffer completion handlers used instead of blocking waits (in GPU path)
- Single command buffer for multi-stage pipelines

### Concerns

1. **`GPULiveFramePipeline` scratch buffer management**: The scratch pool has a budget of 96MB. For high-resolution previews, this could fill quickly. Monitor actual usage.

2. **Kernel library recompilation**: Each module (`NLMeansDenoiseModule`, etc.) compiles its kernel string on every `encode()` call. Cache the compiled `MTLLibrary` and `MTLComputePipelineState` objects.

```swift
// Current: compiles every encode
let library = try device.makeLibrary(source: Self.kernels, options: nil)
guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
encoder.setComputePipelineState(try device.makeComputePipelineState(function: library.makeFunction(name: "...")!))
```

---

## SwiftUI/View Performance

### Observations

1. **`ControlsView.swift:2363`** has a Sendable warning for Toggle bindings. This is a compiler warning, not a runtime issue, but indicates potential for data races if isolations change.

2. **Large `@Published` arrays** (project.images, presets, etc.) trigger full view re-evaluations on change. Consider finer-grained publication for library views.

3. **`libraryThumbnailSize`** is a `@Published Double`. If bound to a slider, every drag event publishes. Ensure the view using this debounces or uses a non-published binding for the live value.

---

## Specific Function-Level Optimizations

### Quick Wins (Low Risk)

| Location | Issue | Suggestion |
|----------|-------|------------|
| `CullEngine.swift:109` | `facetColorHarmony` full iteration | Add step subsampling (e.g., step=2 or 3) |
| `CullEngine.swift:159` | `facetDynamicRange` full sort | Use histogram percentile |
| `CullEngine.swift:368` | Build luma array then 4 passes | Single-pass computation |
| `AppModel.swift:537-547` | Repeated lowercasing in search | Pre-compute lowercase fields at ingest |
| `ImageDecoder.swift:402-409` | CIToneCurve filter recreated | Cache by curve hash |

### Medium Effort

| Location | Issue | Suggestion |
|----------|-------|------------|
| `CullEngine.swift` | Multiple O(n) metric passes | Consolidate into single pass |
| `AppModel.swift:476` | visibleImages recomputes always | Add caching with invalidation |
| `GPUHostGradeEngine.swift` | Pipeline recompilation | Cache MTLComputePipelineState |
| `NativeRenderer.swift` | Output buffer allocation | Consider pooling for repeated sizes |

---

## Verified Good Patterns (Keep As-Is)

These patterns are correctly implemented and should be preserved:

1. ✅ **Latest-wins render scheduling** in AppModel - prevents render queue buildup
2. ✅ **Generation counters** for async work cancellation
3. ✅ **In-flight deduplication** in ImageDecoder and ThumbnailPipeline
4. ✅ **Memory pressure tiered response** (normal → warning → critical)
5. ✅ **GPU-native paths** that avoid CPU readback
6. ✅ **Task cancellation checks** at appropriate points
7. ✅ **reserveCapacity** used before building arrays from known sizes
8. ✅ **Accelerate/vDSP** used for vector operations where appropriate
9. ✅ **Structured concurrency** with TaskGroup for batch operations
10. ✅ **Lazy evaluation** of export statistics (`lazy.filter`)

---

## Test Plan for Changes

If implementing any optimizations:

1. Run `./scripts/qa_10_passes.sh` to verify existing tests pass
2. Compare render times before/after with `--render-integrity-test`
3. Profile with Instruments (Time Profiler, Allocations) on a 5000+ image library
4. Verify CullEngine metrics still produce valid scores after subsampling changes
5. Test memory pressure handling by simulating low-memory conditions

---

## Summary

| Category | Rating | Notes |
|----------|--------|-------|
| Architecture | ⭐⭐⭐⭐⭐ | Well-designed caching, concurrency, and scheduling |
| GPU Usage | ⭐⭐⭐⭐ | Correct Metal usage, some compilation caching opportunities |
| Memory | ⭐⭐⭐⭐ | Good patterns, some allocation opportunities in export path |
| CPU Processing | ⭐⭐⭐ | CullEngine has O(n²)-ish behavior in places |
| SwiftUI | ⭐⭐⭐⭐ | Good patterns, some debouncing opportunities |
| Concurrency | ⭐⭐⭐⭐ | Actor isolation correct, minor mixing with locks |

**Overall**: The codebase is well-engineered for a professional photo editing application. The most impactful changes would be optimizing the CullEngine's full-resolution passes and adding kernel/library caching for the Metal modules.
