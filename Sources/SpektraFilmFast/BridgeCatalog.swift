import Foundation
import CSpektraBridge

enum AppFlavor: Int32, CaseIterable, Codable, Identifiable, Sendable {
    case flow = 0
    case pro = 1
    case dev = 2
    var id: Int32 { rawValue }
    var label: String {
        switch self {
        case .flow: "Flow"
        case .pro: "Pro"
        case .dev: "Dev"
        }
    }
}

enum ParameterKind: Int32, Codable, Sendable {
    case int = 0
    case bool = 1
    case double = 2
    case double2 = 3
    case double3 = 4
    case choice = 5
    case filmStock = 6
    case printPaper = 7
}

enum ParameterValue: Codable, Equatable, Hashable, Sendable {
    case int(Int32)
    case bool(Bool)
    case scalar(Double)
    case vector2(Double, Double)
    case vector3(Double, Double, Double)

    var scalarValue: Double {
        if case let .scalar(v) = self { return v }
        return 0
    }
    var intValue: Int32 {
        switch self {
        case let .int(v): v
        case let .bool(v): v ? 1 : 0
        default: 0
        }
    }
}

struct ParameterDescriptor: Identifiable, Hashable, Sendable {
    let name: String
    let label: String
    let group: String
    let optionSet: String
    let kind: ParameterKind
    let visibilityTier: Int32
    let defaultInt: Int32
    let defaults: (Double, Double, Double)
    let minimum: Double
    let maximum: Double

    var id: String { name }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    var defaultValue: ParameterValue {
        switch kind {
        case .int, .choice, .filmStock, .printPaper:
            .int(defaultInt)
        case .bool:
            .bool(defaultInt != 0)
        case .double:
            .scalar(defaults.0)
        case .double2:
            .vector2(defaults.0, defaults.1)
        case .double3:
            .vector3(defaults.0, defaults.1, defaults.2)
        }
    }
}

struct ParameterGroup: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

final class BridgeCatalog: @unchecked Sendable {
    static let shared = BridgeCatalog()
    let groups: [ParameterGroup]
    let parameters: [ParameterDescriptor]
    private var optionCache: [String: [String]] = [:]
    let films: [String]
    let papers: [String]

    private init() {
        var g: [ParameterGroup] = []
        for i in 0..<SpektraAppGroupCount() {
            guard let ptr = SpektraAppGroupAt(i) else { continue }
            let raw = ptr.pointee
            g.append(ParameterGroup(
                id: raw.id.map(String.init(cString:)) ?? "group\(i)",
                label: raw.label.map(String.init(cString:)) ?? "Group"
            ))
        }
        groups = g

        var p: [ParameterDescriptor] = []
        for i in 0..<SpektraAppParamCount() {
            guard let ptr = SpektraAppParamAt(i), let kind = ParameterKind(rawValue: ptr.pointee.kind) else { continue }
            let raw = ptr.pointee
            p.append(ParameterDescriptor(
                name: raw.name.map(String.init(cString:)) ?? "param\(i)",
                label: raw.label.map(String.init(cString:)) ?? "Parameter",
                group: raw.group.map(String.init(cString:)) ?? "",
                optionSet: raw.optionSet.map(String.init(cString:)) ?? "",
                kind: kind,
                visibilityTier: raw.visibilityTier,
                defaultInt: raw.defaultInt,
                defaults: (raw.defaultValue.0, raw.defaultValue.1, raw.defaultValue.2),
                minimum: raw.minimum,
                maximum: raw.maximum
            ))
        }
        parameters = p

        films = (0..<SpektraAppFilmCount()).compactMap { i in
            SpektraAppFilmName(i).map(String.init(cString:))
        }
        papers = (0..<SpektraAppPaperCount()).compactMap { i in
            SpektraAppPaperName(i).map(String.init(cString:))
        }
    }

    func parameters(in group: String, flavor: AppFlavor) -> [ParameterDescriptor] {
        parameters.filter { descriptor in
            descriptor.group == group && descriptor.visibilityTier <= flavor.rawValue
        }
    }

    func options(for descriptor: ParameterDescriptor) -> [String] {
        if descriptor.kind == .filmStock { return films }
        if descriptor.kind == .printPaper { return papers }
        guard !descriptor.optionSet.isEmpty else { return [] }
        if let cached = optionCache[descriptor.optionSet] { return cached }
        var result: [String] = []
        descriptor.optionSet.withCString { optionSet in
            for i in 0..<SpektraAppOptionCount(optionSet) {
                if let label = SpektraAppOptionLabel(optionSet, i) {
                    result.append(String(cString: label))
                }
            }
        }
        optionCache[descriptor.optionSet] = result
        return result
    }
}
