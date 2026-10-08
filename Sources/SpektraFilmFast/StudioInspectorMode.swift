import Foundation

enum StudioInspectorMode: String, CaseIterable, Identifiable {
    case adjust = "Adjust"
    case film = "Film"
    case masks = "Masks"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .film: return "camera.filters"
        case .masks: return "circle.lefthalf.filled"
        }
    }
}
