import SwiftUI
import Foundation

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(EditorPanelVisibilityStore.key) private var hiddenEditorPanels = ""
    @AppStorage("SpektraFilmStudio.ui.glassEnabled") private var glassEnabled = true
    @AppStorage("SpektraFilmStudio.ui.glassTransparency") private var glassTransparency = 0.60
    private let editorCatalog = BridgeCatalog.shared
    // SFS-UI-SETTINGS-20261009-R2: values are shared with the views they control.
    @AppStorage("SpektraFilmStudio.ui.appearance") private var appAppearance = "system"
    @AppStorage("SpektraFilmStudio.designA.showEditorInspector") private var editorInspectorVisible = true
    @AppStorage("SpektraFilmStudio.designA.showFilmstrip") private var editorFilmstripVisible = true
    @AppStorage("SpektraFilmStudio.designA.showScopes") private var editorScopesVisible = false
    @AppStorage("SpektraFilmStudio.designA.showCullInspector") private var cullInspectorVisible = false
    @AppStorage("SpektraFilmStudio.designA.showLibraryInspector") private var libraryInspectorVisible = false
    @AppStorage("SpektraFilmStudio.designA.v3.showExportBrowser") private var exportBrowserVisible = true
    @AppStorage("SpektraFilmStudio.ui.collapsedFilmSections") private var collapsedFilmSections = ""
    @AppStorage("SpektraFilmStudio.ai.depthProvider") private var depthProvider = "automatic"

    var body: some View {
        // Redlamp uses the macOS 26 `Tab` API ("Appearance", "Models") rather than
        // `.tabItem`. Same spelling, same icon placement, one row per section.
        TabView {
            Tab("Appearance", systemImage: "paintpalette") { uiTab }
            Tab("Color & Scopes", systemImage: "waveform.path.ecg") { studioTab }
            Tab("Models", systemImage: "cpu") { MaskModelsSettingsView() }
            Tab("Shortcuts", systemImage: "keyboard") { shortcutsTab }
            Tab("General", systemImage: "gear") { generalTab }
        }
        .frame(width: 760, height: 610)
        .preferredColorScheme(appAppearance == "dark" ? .dark : (appAppearance == "light" ? .light : nil))
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
                DisclosureGroup("Advanced color handling") {
                    Toggle("Bypass import color transform", isOn: $model.project.preferences.bypassImportTransform)
                        .help("Use only when your source pixels already match the renderer input color space.")
                }
                Toggle("Auto-advance after rating/flag", isOn: $model.project.preferences.autoAdvanceRatings)
                Toggle("Auto-analyze imported photos for Smart Cull", isOn: $model.project.preferences.autoAnalyzeCull)
                Toggle("Write rating, flag, and color changes to XMP", isOn: $model.project.preferences.writeXMPAutomatically)
                Toggle("Autosave and crash recovery", isOn: $model.project.preferences.autosaveEnabled)

                Text("Editing uses a fast preview. Full-resolution preview and export use your original photo.")
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

    // Settings › UI changes exactly the AppStorage properties consumed by each workspace.
    private var uiTab: some View {
        Form {
            Section("Window Appearance") {
                Picker("Appearance", selection: $appAppearance) {
                    Text("Follow macOS").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
                Toggle("Transparent glass panels", isOn: $glassEnabled)
                HStack {
                    Text("Panel transparency")
                    Slider(value: $glassTransparency, in: 0...0.90)
                        .disabled(!glassEnabled)
                    Text("\(Int((glassTransparency * 100).rounded()))%")
                        .monospacedDigit().frame(width: 46)
                }
                Text("The photo itself is never blurred or tinted. Accessibility Reduce Transparency overrides glass.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Workspace Visibility") {
                Toggle("Editor adjustment inspector", isOn: $editorInspectorVisible)
                Toggle("Editor filmstrip", isOn: $editorFilmstripVisible)
                Toggle("Library inspector", isOn: $libraryInspectorVisible)
                Toggle("Cull inspector", isOn: $cullInspectorVisible)
                Toggle("Export source browser", isOn: $exportBrowserVisible)
                Text("These toggles update the workspaces immediately. Essential photo tools remain in their workspaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Adjustment Panel Organization") {
                EditorPanelVisibilityMenu(
                    serializedHidden: $hiddenEditorPanels,
                    panels: [
                        (id: "raw", title: "RAW / White Balance"),
                        (id: "tone", title: "RAW Light"),
                        (id: "density", title: "Film Color Density"),
                        (id: "geometry", title: "Crop / Geometry"),
                        (id: "lens", title: "Lens / Optics")
                    ] + editorCatalog.groups.filter { $0.id != "raw" }.map {
                        (id: "film.\($0.id)", title: $0.label)
                    }
                )
                Button("Expand All Film Sections") { collapsedFilmSections = "" }
            }
            Section("Restore Layout") {
                Button("Restore Default Workspace Layout") {
                    editorInspectorVisible = true
                    editorFilmstripVisible = true
                    editorScopesVisible = false
                    libraryInspectorVisible = false
                    cullInspectorVisible = false
                    exportBrowserVisible = true
                    hiddenEditorPanels = ""
                    collapsedFilmSections = ""
                }
                .help("Only resets UI visibility; does not alter photo edits or masks.")
            }
        }
        .formStyle(.grouped)
        .padding(14)
    }

    private var studioTab: some View {
        Form {
            Section("Editor Scopes") {
                Picker("Scopes appear", selection: $editorScopesVisible) {
                    Text("Hidden").tag(false)
                    Text("Below canvas").tag(true)
                }
                .pickerStyle(.segmented)
                Text("Scopes dock below the canvas so they never shrink the adjustment rail. They start as a slim readout bar and expand only when you ask. Choosing Hidden removes them from the Edit workspace entirely; the toolbar Scopes button still toggles them.")
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
            Section("On-device AI") {
                LabeledContent("Object selection", value: "SAM 2.1 Tiny · 80 MB")
                Text("Subject and people use Apple Vision. Face parts use Vision landmarks. Hair, body skin and clothes use embedded mattes or optional SAM 3. Photos stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
