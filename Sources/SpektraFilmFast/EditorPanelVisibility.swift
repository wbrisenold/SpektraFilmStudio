import SwiftUI

struct EditorPanelVisibilityStore {
    static let key = "SpektraFilmStudio.hiddenEditorPanels"

    static func hidden(from serialized: String) -> Set<String> {
        Set(serialized.split(separator: ",").map(String.init))
    }

    static func serialize(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }
}

struct EditorPanelVisibilityMenu: View {
    @Binding var serializedHidden: String
    let panels: [(id: String, title: String)]

    var body: some View {
        Menu {
            Section("Show panels") {
                ForEach(panels, id: \.id) { panel in
                    let hidden = EditorPanelVisibilityStore.hidden(from: serializedHidden)
                    Toggle(panel.title, isOn: Binding(
                        get: { !hidden.contains(panel.id) },
                        set: { visible in
                            var next = EditorPanelVisibilityStore.hidden(from: serializedHidden)
                            if visible { next.remove(panel.id) } else { next.insert(panel.id) }
                            serializedHidden = EditorPanelVisibilityStore.serialize(next)
                        }
                    ))
                }
            }
            Divider()
            Button("Show All Panels") { serializedHidden = "" }
        } label: {
            Label("Panels", systemImage: "rectangle.3.group")
        }
        .help("Hide inspector panels without changing their settings or render behavior.")
    }
}
