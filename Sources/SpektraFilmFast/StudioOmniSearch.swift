import AppKit
import SwiftUI

/// Single cross-workspace command search, inspired by Redlamp's command palette.
/// Original implementation: uses SpektraFilmStudio's native model and stock catalogue.
enum StudioOmniEvents {
    static let open = Notification.Name("SpektraFilmStudio.Omni.open")
    static let focusAdjustment = Notification.Name("SpektraFilmStudio.Omni.focusAdjustment")
    static let openSceneAssistant = Notification.Name("SpektraFilmStudio.SceneAssistant.open")
}

private enum OmniCommand: Hashable {
    case workspace(WorkspacePage)
    case photo(UUID)
    case film(Int)
    case paper(Int)
    case adjustment(String)
    case task(String)
}

private struct OmniEntry: Identifiable {
    let title: String
    let context: String
    let icon: String
    let keywords: String
    let action: OmniCommand
    var id: String { "\(action)" }
}

private enum OmniMatcher {
    // Redlamp's exact three-level word matcher, then its stable section/title order.
    static func rank(_ query: String, entries: [OmniEntry]) -> [OmniEntry] {
        let words = RedlampSearchMatcher.words(query)
        if words.isEmpty { return Array(entries.prefix(36)) }
        let exact = RedlampSearchMatcher.normalized(query)
        let scored = entries.enumerated().compactMap { index, entry -> (OmniEntry, Int, Bool, Int)? in
            guard let score = RedlampSearchMatcher.score(words, terms:
                [entry.title, entry.context, entry.keywords]) else { return nil }
            return (entry, score, RedlampSearchMatcher.normalized(entry.title) == exact, index)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 }
            return a.3 < b.3
        }.prefix(60).map(\.0)
    }
}

struct StudioOmniSearch: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selected = 0
    @AppStorage("SpektraFilmStudio.ui.glassTransparency") private var transparency = 0.60

    private var entries: [OmniEntry] {
        var result = WorkspacePage.allCases.map {
            OmniEntry(title: $0.title, context: "Workspace", icon: $0.systemImage,
                      keywords: "navigate page", action: .workspace($0))
        }
        result += [
            OmniEntry(title: "Scene Intelligence", context: "Group shoots · recommend film and paper",
                      icon: "sparkles.rectangle.stack", keywords: "ai similar studio shots stock print scene", action: .task("scenes")),
            OmniEntry(title: "Import Photos", context: "Library", icon: "plus", keywords: "add files", action: .task("import")),
            OmniEntry(title: "New Project", context: "Project", icon: "folder.badge.plus", keywords: "create", action: .task("new")),
            OmniEntry(title: "Save Project", context: "Project", icon: "square.and.arrow.down", keywords: "save", action: .task("save")),
            OmniEntry(title: "Copy Look", context: "Edit", icon: "doc.on.doc", keywords: "copy settings", action: .task("copy")),
            OmniEntry(title: "Paste Look", context: "Edit", icon: "doc.on.clipboard", keywords: "paste settings", action: .task("paste")),
            OmniEntry(title: "Sync Look to Highlighted", context: "Edit · keep individual WB and crop",
                      icon: "square.stack.3d.up", keywords: "batch edit apply", action: .task("sync")),
            OmniEntry(title: "Export Selected", context: "Export", icon: "square.and.arrow.up", keywords: "queue deliver", action: .task("export"))
        ]
        result += BridgeCatalog.shared.parameters.map { parameter in
            OmniEntry(title: parameter.label, context: "Adjustment · \(parameter.group)", icon: "slider.horizontal.3",
                      keywords: parameter.name + " " + parameter.group, action: .adjustment(parameter.name))
        }
        result += BridgeCatalog.shared.films.enumerated().map { i, name in
            OmniEntry(title: name, context: "Film Stock · apply to selected photo", icon: "camera.filters",
                      keywords: "film stock negative", action: .film(i))
        }
        result += BridgeCatalog.shared.papers.enumerated().map { i, name in
            OmniEntry(title: name, context: "Print Paper · apply to selected photo", icon: "square.stack",
                      keywords: "print paper", action: .paper(i))
        }
        // File names are indexed without loading image data or cloud originals.
        result += model.project.images.map { image in
            OmniEntry(title: image.fileName, context: "Photo", icon: "photo",
                      keywords: (image.keywords ?? []).joined(separator: " "), action: .photo(image.id))
        }
        return result
    }

    private var matches: [OmniEntry] { OmniMatcher.rank(query, entries: entries) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.contentShape(Rectangle()).onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "command.square").foregroundStyle(.secondary)
                    RedlampPaletteQueryField(
                        text: query,
                        placeholder: "Search photos, commands, stock, paper, adjustments…",
                        textColor: .labelColor,
                        placeholderColor: .secondaryLabelColor,
                        colorScheme: colorScheme,
                        revision: 0,
                        selectsAll: false,
                        onChange: { query = $0 },
                        onKey: { key in
                            switch key {
                            case .up: move(-1); return true
                            case .down: move(1); return true
                            case .submit: activateSelected(); return true
                            case .escape: isPresented = false; return true
                            case .reset: query = ""; return true
                            case .deleteBackward: return false
                            case .left, .right: return false
                            }
                        }
                    )
                        .frame(height: 34)
                    Text("ESC").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                Button { activate(item) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.icon).frame(width: 20)
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(item.context).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if selected == index { Image(systemName: "return").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    .padding(.horizontal, 14).frame(height: RedlampPaletteMetrics.rowHeight)
                                    .background(selected == index ? StudioPalette.selected : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(item.id)
                            }
                            if matches.isEmpty {
                                ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                    description: Text("Try a photo name, an adjustment, a film stock, or a command."))
                            }
                        }.padding(8)
                    }.frame(maxHeight: RedlampPaletteMetrics.maxListHeight)
                    .onChange(of: selected) { _, index in
                        guard matches.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(matches[index].id, anchor: .center) }
                    }
                }
                Divider()
                HStack {
                    Text("↑↓ Navigate    ↵ Run    Esc Close")
                    Spacer()
                    Text("Local search · ⌘K")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }
            .frame(width: RedlampPaletteMetrics.width)
            .studioOmniPane()
            .padding(.top, 15)
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = (selected + delta + matches.count) % matches.count
    }
    private func activateSelected() {
        guard matches.indices.contains(selected) else { return }
        activate(matches[selected])
    }
    private func activate(_ item: OmniEntry) {
        isPresented = false
        switch item.action {
        case .workspace(let page): model.showProjectHome = false; model.page = page
        case .photo(let id):
            model.selectLibraryImage(id)
            model.showProjectHome = false
            model.page = .edit
        case .film(let i):
            guard model.selectedImage != nil else { return }
            model.setParameter("film", value: .int(Int32(i)), interactive: false)
            model.page = .edit
            NotificationCenter.default.post(name: StudioOmniEvents.focusAdjustment, object: "film")
        case .paper(let i):
            guard model.selectedImage != nil else { return }
            model.setParameter("paper", value: .int(Int32(i)), interactive: false)
            model.page = .edit
            NotificationCenter.default.post(name: StudioOmniEvents.focusAdjustment, object: "paper")
        case .adjustment(let name):
            model.page = .edit
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: StudioOmniEvents.focusAdjustment, object: name)
            }
        case .task(let command):
            switch command {
            case "scenes": NotificationCenter.default.post(name: StudioOmniEvents.openSceneAssistant, object: nil)
            case "import": model.importImages()
            case "new": model.newProject()
            case "save": model.saveProject()
            case "copy": model.copyLook()
            case "paste": model.pasteLook()
            case "sync": model.syncActiveLookToHighlighted(copyWhiteBalance: false, copyGeometry: false)
            case "export": model.page = .export
            default: break
            }
        }
    }
}
