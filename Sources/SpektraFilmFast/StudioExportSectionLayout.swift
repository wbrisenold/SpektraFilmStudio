import SwiftUI

// The source-level counterpart of RedlampUI/Export/ExportSheetSections.swift.
// Keeping explicit Location / File / Size / Metadata slots makes each delivery
// group independently testable without duplicating the controls or save engine.
struct StudioExportSectionLayout<Location: View, File: View, Size: View, Metadata: View>: View {
    let disabled: Bool
    let location: Location
    let file: File
    let size: Size
    let metadata: Metadata

    init(disabled: Bool,
         @ViewBuilder location: () -> Location,
         @ViewBuilder file: () -> File,
         @ViewBuilder size: () -> Size,
         @ViewBuilder metadata: () -> Metadata) {
        self.disabled = disabled
        self.location = location()
        self.file = file()
        self.size = size()
        self.metadata = metadata()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                section("Location") { location }
                section("File") { file }
                section("Size") { size }
                section("Metadata") { metadata }
            }
            .padding(12)
        }
        .disabled(disabled)
    }

    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(StudioType.section)
                .tracking(StudioType.sectionTracking)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
