import Foundation

// This preserves the original ExportView source-filter and user-preset data model,
// moved into a standalone module like RedlampUI/Export/ExportPresetStore.swift.
// It does not change the project's persisted preset keys or serialization.
enum ExportSourceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case queued = "Queued"
    case picks = "Picks"
    case client = "Client"
    case rated = "4+"
    case rejected = "Rejected"
    var id: String { rawValue }
}

struct StudioExportUserPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var settings: ExportSettings
}
