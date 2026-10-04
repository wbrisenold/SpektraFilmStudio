import SwiftUI

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
                LabeledContent("Edit working file") { Text("1080 px long edge").monospacedDigit() }
                LabeledContent("Live slider render") { Text("1080 px long edge").monospacedDigit() }
                LabeledContent("Idle edit preview") { Text("1080 px long edge").monospacedDigit() }
                Toggle("Paper background", isOn: $model.project.preferences.paperBackground)
                Toggle("Bypass import transform", isOn: $model.project.preferences.bypassImportTransform)
                Toggle("Auto-advance after rating/flag", isOn: $model.project.preferences.autoAdvanceRatings)
                Toggle("Auto-analyze imported photos for Smart Cull", isOn: $model.project.preferences.autoAnalyzeCull)
                Toggle("Write rating, flag, and color changes to XMP", isOn: $model.project.preferences.writeXMPAutomatically)
                Toggle("Autosave and crash recovery", isOn: $model.project.preferences.autosaveEnabled)

                Text("SpektraFilm creates one cached 1080 px linear working file and edits from it instead of redeveloping the RAW for every slider move. Live dragging and the idle edit preview both stay at 1080 px. Full Resolution Preview and Export are the only paths that reopen the original source and apply the saved recipe at full resolution.")
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
                    Button("Refresh Stats") { model.refreshCacheStatus() }
                    Menu("Clear Cache") {
                        Button("Thumbnails", role: .destructive) { model.clearThumbnailCache() }
                        Button("Working Files / Developed Source", role: .destructive) { model.clearDevelopedSourceCache() }
                        Button("Adjusted Previews", role: .destructive) { model.clearAdjustedPreviewCache() }
                        Button("Smart Cull", role: .destructive) { model.clearCullAnalysisCache() }
                        Divider()
                        Button("Clear All", role: .destructive) { model.clearLocalCaches() }
                    }
                }

                if !model.cacheStatus.isEmpty {
                    Text(model.cacheStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("The cache can live on an internal SSD, another local volume, or a mounted external drive. SpektraFilmFast creates a visible “SpektraFilmFast Cache” folder inside the selected location. If that drive is disconnected, disk caching is marked unavailable instead of silently moving elsewhere.")
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
                            Button { model.setClippingHighlightThreshold(0.998) } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain).help("Reset hard highlight clipping to 99.8%.")
                            Text(model.project.preferences.clippingHighlightThreshold, format: .percent.precision(.fractionLength(1)))
                                .monospacedDigit().frame(width: 52)
                        }
                    }

                    LabeledContent("Hard shadow") {
                        HStack {
                            Slider(value: Binding(
                                get: { model.project.preferences.clippingShadowThreshold },
                                set: { model.setClippingShadowThreshold($0) }
                            ), in: 0.0...0.02)
                            .help("Marks pixels that are essentially at black. This is the stronger blue warning.")
                            Button { model.setClippingShadowThreshold(0.002) } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.plain).help("Reset hard shadow clipping to 0.2%.")
                            Text(model.project.preferences.clippingShadowThreshold, format: .percent.precision(.fractionLength(1)))
                                .monospacedDigit().frame(width: 52)
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

                Text("Exposure warnings are calculated from the final rendered image after White Balance, tone/curves, SpektraFilm stock/print processing, and Crop/Geometry. They are display-only and never exported.")
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
                Text("Use simple key names such as left, right, p, x, or u. Standard macOS command shortcuts remain unchanged.")
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
            TextField("Key", text: text)
                .frame(width: 100)
                .textFieldStyle(.roundedBorder)
        }
    }
}
