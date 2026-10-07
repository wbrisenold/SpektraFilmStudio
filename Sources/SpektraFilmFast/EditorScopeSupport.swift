import Foundation
import CoreGraphics

@MainActor
extension AppModel {
    func setEditorScopeMode(_ mode: ScopeMode) {
        project.preferences.scopeMode = mode
        if mode == .skinVectorscope { refreshStudioAnalysis() }
        requestEditorScopeUpdate()
    }

    func setEditorScopeEnabled(_ enabled: Bool) {
        // Scopes are a permanent editor monitor. Keep the persisted field for old project
        // compatibility, but normalize it on instead of allowing the Edit workspace to hide it.
        project.preferences.scopeEnabled = true
        requestEditorScopeUpdate()
    }

    /// Marks the newest published frame as needing scope analysis. There is at most one
    /// scope task. It samples the latest frame at execution time, so rapid slider traffic
    /// cannot build a scope queue and cannot delay the renderer.
    func requestEditorScopeUpdate() {
        guard page == .edit, latestRenderedBuffer != nil else { return }
        scopeGeneration += 1
        if scopeTask == nil { startEditorScopeLoop() }
    }

    private func startEditorScopeLoop() {
        let analyzer = scopeEngine
        scopeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, page == .edit {
                let requestedGeneration = scopeGeneration
                // Scope work is deliberately subordinate to pointer-rate editing. While the
                // film renderer is busy, cap analysis at 8 fps; at idle it returns to the
                // user's configured cadence (Alcedo uses the same independent-scope idea).
                let requestedFPS = max(5, min(30, project.preferences.scopeTargetFPS))
                let fps = (isRendering || isInteractiveEditActive) ? min(8, requestedFPS) : requestedFPS
                let interval = 1.0 / Double(fps)
                let elapsed = ProcessInfo.processInfo.systemUptime - lastScopeUpdateUptime
                if elapsed < interval {
                    try? await Task.sleep(for: .seconds(interval - elapsed))
                }
                guard !Task.isCancelled,
                      page == .edit,
                      let frame = latestRenderedBuffer else { break }

                isScopeAnalyzing = true
                let mode = project.preferences.scopeMode
                do {
                    let payload = try await analyzer.analyze(
                        frame,
                        look: selectedLook,
                        mode: mode,
                        skinToleranceDegrees: project.preferences.skinToleranceDegrees,
                        skinMaskWidth: latestSkinMaskWidth,
                        skinMaskHeight: latestSkinMaskHeight,
                        skinMaskAlpha: latestSkinMaskAlpha,
                        skinMeanCbNormalized: analysisMetrics.skinMeanCbNormalized,
                        skinMeanCrNormalized: analysisMetrics.skinMeanCrNormalized,
                        skinMeanDeviationDegrees: analysisMetrics.skinMeanDeviationDegrees,
                        skinMeasurementConfidencePercent: analysisMetrics.skinMeasurementConfidencePercent
                    )
                    guard !Task.isCancelled, page == .edit else { break }
                    // Never publish a completed trace over a newer frame/slider generation.
                    if requestedGeneration != scopeGeneration { continue }
                    editorScopeImage = CGImage.fromRGBA8(width: payload.width, height: payload.height, bytes: payload.rgba)
                    lastScopeUpdateUptime = ProcessInfo.processInfo.systemUptime
                } catch {
                    // Scope failures never fail or interrupt the edit render path.
                }
                isScopeAnalyzing = false

                if requestedGeneration == scopeGeneration { break }
            }
            isScopeAnalyzing = false
            scopeTask = nil
            if !Task.isCancelled,
               page == .edit,
               latestRenderedBuffer != nil,
               scopeGeneration > 0,
               ProcessInfo.processInfo.systemUptime - lastScopeUpdateUptime > 0.05 {
                // A frame may have landed between the final generation check and task cleanup.
                requestEditorScopeUpdate()
            }
        }
    }
}
