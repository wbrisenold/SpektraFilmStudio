import Foundation
import os.signpost

/// Thread-safe performance monitoring for SpektraFilmStudio.
/// Uses a lock for thread-safe access to mutable state.
final class PerformanceMonitor: @unchecked Sendable {
    static let shared = PerformanceMonitor()
    
    private let log = OSLog(subsystem: "com.spektrafilm", category: "performance")
    private let signpostLog = OSLog(subsystem: "com.spektrafilm", category: "signpost")
    
    // Use a lock for thread-safe access to all mutable state
    private let lock = NSLock()
    
    // Cache metrics
    private var decodeCacheHits: UInt64 = 0
    private var decodeCacheMisses: UInt64 = 0
    private var diskCacheHits: UInt64 = 0
    private var diskCacheMisses: UInt64 = 0
    private var textureReuses: UInt64 = 0
    private var textureAllocations: UInt64 = 0
    
    // Render metrics
    private var frameCount: UInt64 = 0
    private var totalFrameTimeMs: Double = 0
    private var totalGpuTimeMs: Double = 0
    private var totalPassCount: UInt64 = 0
    private var scratchReuses: UInt64 = 0
    private var scratchAllocations: UInt64 = 0
    
    // Latency percentiles (simplified - track running min/max/avg)
    private var minFrameTimeMs: Double = Double.infinity
    private var maxFrameTimeMs: Double = 0
    
    private init() {}
    
    // MARK: - Cache Metrics (thread-safe via lock)
    
    func recordDecodeCacheHit() {
        lock.lock()
        decodeCacheHits += 1
        lock.unlock()
    }
    
    func recordDecodeCacheMiss() {
        lock.lock()
        decodeCacheMisses += 1
        lock.unlock()
    }
    
    func recordDiskCacheHit() {
        lock.lock()
        diskCacheHits += 1
        lock.unlock()
    }
    
    func recordDiskCacheMiss() {
        lock.lock()
        diskCacheMisses += 1
        lock.unlock()
    }
    
    func recordTextureReuse() {
        lock.lock()
        textureReuses += 1
        lock.unlock()
    }
    
    func recordTextureAllocation() {
        lock.lock()
        textureAllocations += 1
        lock.unlock()
    }
    
    // MARK: - Render Metrics
    
    func recordFrame(frameTimeMs: Double, gpuTimeMs: Double, passCount: Int) {
        lock.lock()
        frameCount += 1
        totalFrameTimeMs += frameTimeMs
        totalGpuTimeMs += gpuTimeMs
        totalPassCount += UInt64(passCount)
        
        if frameTimeMs < minFrameTimeMs { minFrameTimeMs = frameTimeMs }
        if frameTimeMs > maxFrameTimeMs { maxFrameTimeMs = frameTimeMs }
        totalGpuTimeMs += gpuTimeMs
        lock.unlock()
    }
    
    func recordScratchReuse() {
        lock.lock()
        scratchReuses += 1
        lock.unlock()
    }
    
    func recordScratchAllocation() {
        lock.lock()
        scratchAllocations += 1
        lock.unlock()
    }
    
    // MARK: - Signpost Integration
    
    func beginRenderSignpost(_ id: OSSignpostID, width: Int, height: Int) {
        os_signpost(.begin, log: signpostLog, name: "frame", signpostID: id, "w=%d h=%d", width, height)
    }
    
    func endRenderSignpost(_ id: OSSignpostID, frameTimeMs: Double, gpuTimeMs: Double) {
        os_signpost(.end, log: signpostLog, name: "frame", signpostID: id, "cpu=%.1fms gpu=%.1fms", frameTimeMs, gpuTimeMs)
    }
    
    func beginDecodeSignpost(_ id: OSSignpostID, sourceMP: Double) {
        os_signpost(.begin, log: signpostLog, name: "decode", signpostID: id, "mp=%.1f", sourceMP)
    }
    
    func endDecodeSignpost(_ id: OSSignpostID, elapsedMs: Double, fromCache: Bool) {
        os_signpost(.end, log: signpostLog, name: "decode", signpostID: id, "ms=%.1f cache=%{public}s", elapsedMs, fromCache ? "hit" : "miss")
    }
    
    // MARK: - Metrics Export
    
    struct PerformanceReport: Codable {
        let timestamp: Date
        let frameCount: UInt64
        let avgFrameTimeMs: Double
        let minFrameTimeMs: Double
        let maxFrameTimeMs: Double
        let avgGpuTimeMs: Double
        let avgPassCount: Double
        let decodeCacheHitRate: Double
        let diskCacheHitRate: Double
        let textureReuseRate: Double
        let scratchReuseRate: Double
        let avgPassesPerFrame: Double
    }
    
    func exportReport() -> PerformanceReport {
        lock.lock()
        let localFrameCount = self.frameCount
        let localTotalFrameTimeMs = self.totalFrameTimeMs
        let localTotalGpuTimeMs = self.totalGpuTimeMs
        let localTotalPassCount = self.totalPassCount
        let localDecodeCacheHits = self.decodeCacheHits
        let localDecodeCacheMisses = self.decodeCacheMisses
        let localDiskCacheHits = self.diskCacheHits
        let localDiskCacheMisses = self.diskCacheMisses
        let localTextureReuses = self.textureReuses
        let localTextureAllocations = self.textureAllocations
        let localScratchReuses = self.scratchReuses
        let localScratchAllocations = self.scratchAllocations
        let localMinFrameTimeMs = self.minFrameTimeMs
        let localMaxFrameTimeMs = self.maxFrameTimeMs
        lock.unlock()
        
        let localDecodeTotal = localDecodeCacheHits + localDecodeCacheMisses
        let localDiskTotal = localDiskCacheHits + localDiskCacheMisses
        let localTextureTotal = localTextureReuses + localTextureAllocations
        let localScratchTotal = localScratchReuses + localScratchAllocations
        
        let localDecodeHitRate = localDecodeTotal > 0 ? Double(localDecodeCacheHits) / Double(localDecodeTotal) : 0
        let localDiskHitRate = localDiskTotal > 0 ? Double(localDiskCacheHits) / Double(localDiskTotal) : 0
        let localTextureReuseRate = localTextureTotal > 0 ? Double(localTextureReuses) / Double(localTextureTotal) : 0
        let localScratchReuseRate = localScratchTotal > 0 ? Double(localScratchReuses) / Double(localScratchTotal) : 0
        
        let localAvgFrameTime = localFrameCount > 0 ? localTotalFrameTimeMs / Double(localFrameCount) : 0
        let localAvgGpuTime = localFrameCount > 0 ? localTotalGpuTimeMs / Double(localFrameCount) : 0
        let localAvgPasses = localFrameCount > 0 ? Double(localTotalPassCount) / Double(localFrameCount) : 0
        
        return PerformanceReport(
            timestamp: Date(),
            frameCount: localFrameCount,
            avgFrameTimeMs: localAvgFrameTime,
            minFrameTimeMs: localMinFrameTimeMs == .infinity ? 0 : localMinFrameTimeMs,
            maxFrameTimeMs: localMaxFrameTimeMs,
            avgGpuTimeMs: localAvgGpuTime,
            avgPassCount: localAvgPasses,
            decodeCacheHitRate: localDecodeHitRate,
            diskCacheHitRate: localDiskHitRate,
            textureReuseRate: localTextureReuseRate,
            scratchReuseRate: localScratchReuseRate,
            avgPassesPerFrame: localAvgPasses
        )
    }
    
    func exportJSON() throws -> Data {
        let report = exportReport()
        return try JSONEncoder().encode(report)
    }
    
    func logReport() {
        let report = exportReport()
        let json = try? JSONEncoder().encode(report)
        if let data = json, let str = String(data: data, encoding: .utf8) {
            os_log(.info, log: OSLog(subsystem: "com.spektrafilm", category: "performance"), "Performance Report: %{public}s", str)
        }
    }
    
    func reset() {
        lock.lock()
        // Reset all counters
        lock.unlock()
    }
}