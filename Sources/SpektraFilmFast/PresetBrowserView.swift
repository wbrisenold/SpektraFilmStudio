import SwiftUI

struct PresetBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""
    @State private var newCategory = "Custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets").font(.headline)
            TextField("Search", text: $model.presetSearch).textFieldStyle(.roundedBorder)
            Picker("Category", selection: $model.presetCategoryFilter) {
                ForEach(model.presetCategories, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            List(model.filteredPresets) { preset in
                HStack {
                    VStack(alignment: .leading) { Text(preset.name); Text(preset.category).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Apply") { model.applyPreset(preset) }
                        .buttonStyle(.borderless)
                    Menu { Button("Export…") { model.exportPreset(preset) }; Button("Delete", role: .destructive) { model.deletePreset(preset) } } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                }
            }
            Divider()
            TextField("Preset name", text: $newName)
            TextField("Category", text: $newCategory)
            HStack {
                Button("Save Current") { model.savePreset(name: newName, category: newCategory); newName = "" }
                Button("Import .sfpreset") { model.importPreset() }
            }
        }
        .padding(10)
        .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
    }
}
