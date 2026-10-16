import SwiftUI

/// The source-level counterpart of RedlampUI/Export/ExportSheetSections.swift.
/// Keeping explicit Location / File / Size / Metadata slots makes each delivery
/// group independently testable without duplicating the controls or save engine.
struct StudioExportSectionLayout<Location: View, File: View, Size: View, Metadata: View>: View {
    let disabled: Bool
    @ViewBuilder let location: Location
    @ViewBuilder let file: File
    @ViewBuilder let size: Size
    @ViewBuilder let metadata: Metadata

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

    private func section(_ label: String, @ViewBuilder content: () -> some View) -> some View {
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
