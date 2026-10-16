import Foundation

enum StudioInspectorMode: String, CaseIterable, Identifiable {
    case adjust = "RAW"
    case film = "FILM"
    case masks = "MASK"
    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .film: "camera.filters"
        case .masks: "circle.lefthalf.filled"
        }
    }
}
