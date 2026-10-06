import SwiftUI
import Foundation

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            studioTab
                .tabItem { Label("Studio", systemImage: "waveform.path.ecg") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 660, height: 540)
        .onAppear { model.refreshCacheStatus() }
    }

    private var generalTab: some View {
        Form {
            Section("Preview") {
                LabeledContent("Edit proxy") {
                    Text("1080 px · live + idle")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Toggle("Paper background", isOn: $model.project.preferences.paperBackground)
                Toggle("Bypass import transform", isOn: $model.project.preferences.bypassImportTransform)
                Toggle("Auto-advance after rating/flag", isOn: $model.project.preferences.autoAdvanceRatings)
                Toggle("Auto-analyze imported photos for Smart Cull", isOn: $model.project.preferences.autoAnalyzeCull)
                Toggle("Write rating, flag, and color changes to XMP", isOn: $model.project.preferences.writeXMPAutomatically)
                Toggle("Autosave and crash recovery", isOn: $model.project.preferences.autosaveEnabled)

                Text("One cached 1080 px linear proxy drives Edit. Full Resolution Preview and Export reopen the original source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Cache") {
                Picker("RAM cache", selection: Binding(
                    get: { model.cacheMemoryMode },
                    set: { model.setCacheMemoryMode($0) }
                )) {
                    ForEach(PreviewCacheMemoryMode.allCases) { Text($0.rawValue).tag($0) }
                }

                Stepper(
                    "Disk budget: \(model.localDiskCacheGB) GB",
                    value: Binding(
                        get: { model.localDiskCacheGB },
                        set: { model.setLocalDiskCacheGB($0) }
                    ),
                    in: 2...100,
                    step: 1
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.cacheLocationAvailable ? "Cache folder" : "Cache drive unavailable")
                        Spacer()
                        if !model.cacheDirectoryParentPath.isEmpty {
                            Text("Custom")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(model.cacheRootPath.isEmpty ? "Configuring…" : model.cacheRootPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(model.cacheLocationAvailable ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)

                    HStack {
                        Button("Choose Folder…") { model.chooseCacheFolder() }
                        Button("Reveal in Finder") { model.revealCacheInFinder() }
                            .disabled(!model.cacheLocationAvailable)
                        if !model.cacheDirectoryParentPath.isEmpty {
                            Button("Use Default") { model.useDefaultCacheFolder() }
                        }
                    }
                }

                HStack {
                    Button("Refresh Stats") { model.refreshCacheStatus(); model.refreshStage5CacheAccounting() }
                    Button("Validate Separation") { model.validateCacheHealth(); model.refreshStage5CacheAccounting() }
                    Menu("Clear Cache") {
                        Button("Thumbnails", role: .destructive) { model.clearThumbnailCache() }
                        Button("Working Files / Developed Source", role: .destructive) { model.clearDevelopedSourceCache() }
                        Button("Adjusted Previews", role: .destructive) { model.clearAdjustedPreviewCache() }
                        Button("Smart Cull", role: .destructive) { model.clearCullAnalysisCache() }
                        Divider()
                        Button("Clear All", role: .destructive) { model.clearLocalCaches() }
                    }
                }

                if !model.cacheHealthStatus.isEmpty { Text(model.cacheHealthStatus).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }

                if !model.cacheStatus.isEmpty {
                    Text(model.cacheStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("The cache can live on an internal SSD, another local volume, or a mounted external drive. SpektraFilm Studio creates a visible “SpektraFilmFast Cache” folder inside the selected location. If that drive is disconnected, disk caching is marked unavailable instead of silently moving elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }

    private var studioTab: some View {
        Form {
            Section("Editor Scopes") {
                LabeledContent("Visibility") {
                    Text("Always on in Edit")
                        .foregroundStyle(.secondary)
                }
                Text("Scopes stay visible while you edit so you can judge exposure and color without opening another panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Default scope", selection: Binding(
                    get: { model.project.preferences.scopeMode },
                    set: { model.setEditorScopeMode($0) }
                )) {
                    ForEach(ScopeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper(
                    "Scope refresh: \(model.project.preferences.scopeTargetFPS) fps",
                    value: $model.project.preferences.scopeTargetFPS,
                    in: 5...30,
                    step: 1
                )
            }

            Section("Exposure Warning") {
                Picker("Clipping preview", selection: Binding(
                    get: { model.project.preferences.clippingPreviewMode },
                    set: { model.setClippingPreviewMode($0) }
                )) {
                    ForEach(ClippingPreviewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .help("Darktable-style final-output clipping test. Full Gamut combines luminance, RGB-channel, and saturation/gamut warnings and is the default.")

                LabeledContent("Bright warning") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.project.preferences.exposureHighlightRiskThreshold },
                            set: { model.setExposureHighlightRiskThreshold($0) }
                        ), in: 0.75...0.99)
                        .help("Warns before bright detail is fully clipped. Move left to flag bright areas sooner; move right to warn only very close to white.")
                        Button { model.setExposureHighlightRiskThreshold(0.95) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).help("Reset bright warning to 95%.")
                        Text(model.project.preferences.exposureHighlightRiskThreshold, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 48)
                    }
                }

                LabeledContent("Dark warning") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.project.preferences.exposureShadowRiskThreshold },
                            set: { model.setExposureShadowRiskThreshold($0) }
                        ), in: 0.002...0.12)
                        .help("Warns before shadow detail collapses to black. Move right to flag dark areas sooner; move left to warn only on extremely dark pixels.")
                        Button { model.setExposureShadowRiskThreshold(0.02) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).help("Reset dark warning to 2%.")
                        Text(model.project.preferences.exposureShadowRiskThreshold, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit().frame(width: 48)
                    }
                }

                DisclosureGroup("Hard clipping thresholds") {
                    LabeledContent("Hard highlight") {
                        HStack {
                            Slider(value: Binding(
                                get: { model.project.preferences.clippingHighlightThreshold },
                                set: { model.setClippingHighlightThreshold($0) }
                            ), in: 0.95...1.0)
                            .help("Marks pixels that are essentially at pure white. This is the stronger red warning.")
                            Button { model.setClippingHighlightThreshold(0.9999) } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain).help("Reset hard highlight clipping to darktable's current source default of 99.99%.")
                            Text(model.project.preferences.clippingHighlightThreshold, format: .percent.precision(.fractionLength(2)))
                                .monospacedDigit().frame(width: 58)
                        }
                    }

                    LabeledContent("Hard shadow") {
                        HStack {
                            Slider(value: Binding(
                                get: { log2(max(1.0e-12, model.project.preferences.clippingShadowThreshold)) },
                                set: { ev in model.setClippingShadowThreshold(pow(2.0, ev)) }
                            ), in: -22.0 ... -4.0)
                            .help("Lower clipping threshold in EV relative to white, matching darktable's clipping-warning convention.")
                            Button { model.setClippingShadowThreshold(pow(2.0, -12.69)) } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain).help("Reset to -12.69 EV, darktable's 8-bit sRGB black reference.")
                            Text("\(log2(max(1.0e-12, model.project.preferences.clippingShadowThreshold)), specifier: "%.2f") EV")
                                .monospacedDigit().frame(width: 72)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Label("Risk", systemImage: "circle.fill")
                        .foregroundStyle(.secondary)
                    Text("lighter overlay = detail is getting dangerous")
                    Label("Hard clip", systemImage: "circle.fill")
                        .foregroundStyle(.primary)
                    Text("strong overlay = detail has effectively hit white/black")
                }
                .font(.caption2)

                Text("Hard clipping follows darktable-style Full Gamut / RGB / luminance / saturation tests with red-over and blue-under defaults. SpektraFilm Studio keeps an additional translucent risk layer before hard clipping. All tests use the final rendered image after White Balance, tone/curves, SpektraFilm stock/print processing, and Crop/Geometry; they are display-only and never exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Skin Check") {
                LabeledContent("Skin-line tolerance") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.project.preferences.skinToleranceDegrees },
                            set: { model.setSkinTolerance($0) }
                        ), in: 1...45)
                        .help("Sets how far skin can drift from the skin-tone reference before it is flagged. Smaller is stricter; larger allows more variation from lighting and creative color.")
                        Button { model.setSkinTolerance(12) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).help("Reset skin-line tolerance to ±12°.")
                        Text("±\(Int(model.project.preferences.skinToleranceDegrees))°")
                            .monospacedDigit().frame(width: 48)
                    }
                }
                LabeledContent("Overlay opacity") {
                    HStack {
                        Slider(value: Binding(
                            get: { model.project.preferences.skinOverlayOpacity },
                            set: { model.setSkinOverlayOpacity($0) }
                        ), in: 0.05...0.85)
                        .help("Controls how strongly the skin diagnostic is drawn over the photo. Lower keeps more of the photo visible; higher makes the mask easier to see.")
                        Button { model.setSkinOverlayOpacity(0.30) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).help("Reset skin overlay opacity to 30%.")
                        Text(model.project.preferences.skinOverlayOpacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 48)
                    }
                }
                Text("Skin Check first isolates people with Apple Vision, then classifies skin using published open-source YCbCr and HSV ranges spanning a wide range of complexions. The Skin Vector scope uses only those detected skin pixels; the overlay is display-only and never exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }

    private var shortcutsTab: some View {
        Form {
            Section("Shortcut Keys") {
                shortcut("Previous image", text: $model.project.preferences.shortcutPrevious)
                shortcut("Next image", text: $model.project.preferences.shortcutNext)
                shortcut("Pick", text: $model.project.preferences.shortcutPick)
                shortcut("Reject", text: $model.project.preferences.shortcutReject)
                shortcut("Unflag", text: $model.project.preferences.shortcutUnflag)
                Text("Click a shortcut field, then press the key you want. Escape cancels capture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }

    private func shortcut(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            ShortcutCaptureField(value: text)
                .frame(width: 120, height: 24)
        }
    }
}


private struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> ShortcutCaptureTextField {
        let field = ShortcutCaptureTextField()
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.stringValue = value
        field.onKey = { key in value = key }
        return field
    }

    func updateNSView(_ field: ShortcutCaptureTextField, context: Context) {
        field.stringValue = value
    }
}

private final class ShortcutCaptureTextField: NSTextField {
    var onKey: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        let name: String
        switch event.keyCode {
        case 123: name = "left"
        case 124: name = "right"
        case 125: name = "down"
        case 126: name = "up"
        case 36: name = "return"
        case 48: name = "tab"
        case 49: name = "space"
        case 51: name = "delete"
        default: name = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        guard !name.isEmpty else { return }
        onKey?(name)
        window?.makeFirstResponder(nil)
    }
}
