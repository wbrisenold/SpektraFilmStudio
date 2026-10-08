import Foundation

struct RecoveryEnvelope: Codable, Sendable {
    var savedAt: Date
    var originalProjectPath: String?
    var project: SpektraProjectDocument
}

actor ProjectRecoveryStore {
    static let shared = ProjectRecoveryStore()

    func save(project: SpektraProjectDocument, projectURL: URL?) throws {
        let envelope = RecoveryEnvelope(savedAt: Date(), originalProjectPath: projectURL?.path, project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let target = recoveryURL()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    func latest() -> RecoveryEnvelope? {
        let target = recoveryURL()
        guard let data = try? Data(contentsOf: target) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecoveryEnvelope.self, from: data)
    }

    func clear() {
        Self.clearSynchronously()
    }

    /// Quit/save paths cannot rely on an unstructured async task finishing before the
    /// process exits. Keep this synchronous escape hatch so an explicitly discarded or
    /// successfully saved recovery snapshot cannot reappear on the next launch.
    nonisolated static func clearSynchronously() {
        try? FileManager.default.removeItem(at: recoveryURL())
    }

    nonisolated private static func recoveryURL() -> URL {
        if CommandLine.arguments.contains(where: { ["--picker-smoke-test", "--ux-smoke-test", "--self-test", "--studio-soak-test"].contains($0) }) {
            return FileManager.default.temporaryDirectory.appendingPathComponent("SpektraPicker-Recovery-\(ProcessInfo.processInfo.processIdentifier).json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SpektraFilm/Recovery/latest.json")
    }

    private func recoveryURL() -> URL { Self.recoveryURL() }
}
