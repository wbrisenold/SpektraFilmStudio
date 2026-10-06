import Foundation
import AppKit
import CryptoKit

enum ManagedIngestItemState: String, Codable, Sendable {
    case pending, primaryCopied, completed, failed
}

struct ManagedIngestItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sourcePath: String
    let relativePath: String
    let primaryPath: String
    let backupPath: String
    var state: ManagedIngestItemState
    var sha256: String?
    var errorMessage: String?

    init(source: URL, relativePath: String, primary: URL, backup: URL) {
        id = UUID()
        sourcePath = source.path
        self.relativePath = relativePath
        primaryPath = primary.path
        backupPath = backup.path
        state = .pending
        sha256 = nil
        errorMessage = nil
    }
}

struct ManagedIngestJob: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let sourceRoot: String
    let primaryRoot: String
    let backupRoot: String
    var items: [ManagedIngestItem]
    var updatedAt: Date

    init(sourceRoot: URL, primaryRoot: URL, backupRoot: URL, items: [ManagedIngestItem]) {
        id = UUID()
        createdAt = Date()
        self.sourceRoot = sourceRoot.path
        self.primaryRoot = primaryRoot.path
        self.backupRoot = backupRoot.path
        self.items = items
        updatedAt = createdAt
    }

    var completedCount: Int { items.lazy.filter { $0.state == .completed }.count }
    var fractionComplete: Double {
        guard !items.isEmpty else { return 0 }
        return Double(completedCount) / Double(items.count)
    }
}

struct ManagedIngestProgress: Sendable {
    let completed: Int
    let total: Int
    let fileName: String
    let message: String
}

enum ManagedIngestError: LocalizedError {
    case sameDestination
    case destinationInsideSource
    case noPhotos
    case destinationConflict(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sameDestination:
            "Primary and backup destinations must be different folders."
        case .destinationInsideSource:
            "Primary and backup destinations must not be inside the source card/folder."
        case .noPhotos:
            "No supported photos were found in the ingest source."
        case .destinationConflict(let name):
            "A different file already exists at \(name)."
        case .verificationFailed(let name):
            "Checksum verification failed for \(name)."
        }
    }
}

actor ManagedIngestService {
    static let shared = ManagedIngestService()

    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff", "dng",
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "rwl", "pef", "ptx", "3fr", "fff", "iiq", "mos", "mef", "mrw",
        "erf", "kdc", "dcr", "x3f", "raw", "srw", "bay", "cap", "eip"
    ]

    private var journalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpektraFilm/Ingest/active-ingest.json")
    }

    func makeJob(sourceRoot: URL, primaryRoot: URL, backupRoot: URL) throws -> ManagedIngestJob {
        let source = sourceRoot.standardizedFileURL
        let primary = primaryRoot.standardizedFileURL
        let backup = backupRoot.standardizedFileURL
        guard primary.path != backup.path else { throw ManagedIngestError.sameDestination }
        guard !primary.path.hasPrefix(source.path + "/"),
              !backup.path.hasPrefix(source.path + "/") else {
            throw ManagedIngestError.destinationInsideSource
        }

        let sources = photoURLs(in: source)
        guard !sources.isEmpty else { throw ManagedIngestError.noPhotos }

        var items: [ManagedIngestItem] = []
        items.reserveCapacity(sources.count)
        for url in sources {
            let relative = relativePath(of: url, under: source)
            let primaryURL = primary.appendingPathComponent(relative)
            let backupURL = backup.appendingPathComponent(relative)
            items.append(ManagedIngestItem(
                source: url,
                relativePath: relative,
                primary: primaryURL,
                backup: backupURL
            ))
        }

        let job = ManagedIngestJob(
            sourceRoot: source,
            primaryRoot: primary,
            backupRoot: backup,
            items: items
        )
        try save(job)
        return job
    }

    func recoverableJob() -> ManagedIngestJob? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ManagedIngestJob.self, from: data)
    }

    func run(
        job initial: ManagedIngestJob,
        progress: @escaping @Sendable (ManagedIngestProgress) -> Void
    ) async throws -> (ManagedIngestJob, [URL]) {
        var job = initial
        let total = job.items.count

        for index in job.items.indices {
            try Task.checkCancellation()
            if job.items[index].state == .completed { continue }

            let source = URL(fileURLWithPath: job.items[index].sourcePath)
            let primary = URL(fileURLWithPath: job.items[index].primaryPath)
            let backup = URL(fileURLWithPath: job.items[index].backupPath)
            let name = source.lastPathComponent

            do {
                progress(ManagedIngestProgress(
                    completed: job.completedCount,
                    total: total,
                    fileName: name,
                    message: "Copying primary…"
                ))
                let sourceHash = try await verifiedCopy(source: source, destination: primary, expectedHash: nil)
                job.items[index].sha256 = sourceHash
                job.items[index].state = .primaryCopied
                job.items[index].errorMessage = nil
                job.updatedAt = Date()
                try save(job)

                try Task.checkCancellation()
                progress(ManagedIngestProgress(
                    completed: job.completedCount,
                    total: total,
                    fileName: name,
                    message: "Copying verified backup…"
                ))
                _ = try await verifiedCopy(source: source, destination: backup, expectedHash: sourceHash)

                job.items[index].state = .completed
                job.items[index].errorMessage = nil
                job.updatedAt = Date()
                try save(job)
                progress(ManagedIngestProgress(
                    completed: job.completedCount,
                    total: total,
                    fileName: name,
                    message: "Verified"
                ))
            } catch is CancellationError {
                try? save(job)
                throw CancellationError()
            } catch {
                job.items[index].state = .failed
                job.items[index].errorMessage = error.localizedDescription
                job.updatedAt = Date()
                try? save(job)
                throw error
            }
        }

        let urls = job.items.map { URL(fileURLWithPath: $0.primaryPath) }
        try? FileManager.default.removeItem(at: journalURL)
        return (job, urls)
    }

    func clearJournal() {
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func save(_ job: ManagedIngestJob) throws {
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: journalURL, options: .atomic)
    }

    private func photoURLs(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var values: [URL] = []
        for case let url as URL in enumerator {
            guard let resource = try? url.resourceValues(forKeys: Set(keys)),
                  resource.isRegularFile == true,
                  resource.isHidden != true else { continue }
            if supportedExtensions.contains(url.pathExtension.lowercased()) {
                values.append(url)
            }
        }
        return values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func verifiedCopy(source: URL, destination: URL, expectedHash: String?) async throws -> String {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination.path) {
            let existingHash = try await sha256(url: destination)
            let sourceHash: String
            if let expectedHash { sourceHash = expectedHash } else { sourceHash = try await sha256(url: source) }
            guard existingHash == sourceHash else {
                throw ManagedIngestError.destinationConflict(destination.lastPathComponent)
            }
            return sourceHash
        }

        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: temp) }

        fm.createFile(atPath: temp.path, contents: nil)
        let sourceHandle = try FileHandle(forReadingFrom: source)
        let outputHandle = try FileHandle(forWritingTo: temp)
        defer {
            try? sourceHandle.close()
            try? outputHandle.close()
        }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try sourceHandle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            hasher.update(data: data)
            try outputHandle.write(contentsOf: data)
        }
        try outputHandle.synchronize()
        let sourceHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        if let expectedHash, expectedHash != sourceHash {
            throw ManagedIngestError.verificationFailed(source.lastPathComponent)
        }

        let copiedHash = try await sha256(url: temp)
        guard copiedHash == sourceHash else {
            throw ManagedIngestError.verificationFailed(destination.lastPathComponent)
        }
        try Task.checkCancellation()
        try fm.moveItem(at: temp, to: destination)
        return sourceHash
    }

    private func sha256(url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

@MainActor
extension AppModel {
    func beginManagedIngest() {
        guard !isIngesting else { return }

        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseFiles = false
        sourcePanel.canChooseDirectories = true
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.prompt = "Choose Source"
        sourcePanel.message = "Choose the camera card or source folder."
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }

        let primaryPanel = NSOpenPanel()
        primaryPanel.canChooseFiles = false
        primaryPanel.canChooseDirectories = true
        primaryPanel.canCreateDirectories = true
        primaryPanel.allowsMultipleSelection = false
        primaryPanel.prompt = "Choose Primary"
        primaryPanel.message = "Choose the working photo destination."
        guard primaryPanel.runModal() == .OK, let primary = primaryPanel.url else { return }

        let backupPanel = NSOpenPanel()
        backupPanel.canChooseFiles = false
        backupPanel.canChooseDirectories = true
        backupPanel.canCreateDirectories = true
        backupPanel.allowsMultipleSelection = false
        backupPanel.prompt = "Choose Backup"
        backupPanel.message = "Choose a second drive/folder for the verified backup copy."
        guard backupPanel.runModal() == .OK, let backup = backupPanel.url else { return }

        managedIngestTask?.cancel()
        isIngesting = true
        ingestProgress = 0
        ingestStatus = "Planning verified ingest…"
        let generation = projectGeneration

        managedIngestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let job = try await ManagedIngestService.shared.makeJob(
                    sourceRoot: source,
                    primaryRoot: primary,
                    backupRoot: backup
                )
                try Task.checkCancellation()
                let (_, urls) = try await ManagedIngestService.shared.run(job: job) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.projectGeneration else { return }
                        self.ingestProgress = progress.total == 0
                            ? 0
                            : Double(progress.completed) / Double(progress.total)
                        self.ingestStatus = "\(progress.message) · \(progress.fileName) · \(progress.completed)/\(progress.total)"
                    }
                }
                guard generation == projectGeneration else { throw CancellationError() }
                addImages(urls: urls)
                ingestProgress = 1
                ingestStatus = "Ingest complete · primary + backup verified · \(urls.count) photos"
                hasRecoverableIngest = false
                isIngesting = false
                managedIngestTask = nil
            } catch is CancellationError {
                isIngesting = false
                managedIngestTask = nil
                hasRecoverableIngest = await ManagedIngestService.shared.recoverableJob() != nil
                ingestStatus = "Ingest stopped · progress saved for resume"
            } catch {
                isIngesting = false
                managedIngestTask = nil
                hasRecoverableIngest = await ManagedIngestService.shared.recoverableJob() != nil
                ingestStatus = "Ingest stopped · \(error.localizedDescription)"
            }
        }
    }

    func resumeManagedIngest() {
        guard !isIngesting else { return }
        managedIngestTask?.cancel()
        let generation = projectGeneration
        isIngesting = true
        ingestStatus = "Resuming verified ingest…"

        managedIngestTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let job = await ManagedIngestService.shared.recoverableJob() else {
                    isIngesting = false
                    hasRecoverableIngest = false
                    ingestStatus = "No resumable ingest found"
                    return
                }
                let (_, urls) = try await ManagedIngestService.shared.run(job: job) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.projectGeneration else { return }
                        self.ingestProgress = progress.total == 0
                            ? 0
                            : Double(progress.completed) / Double(progress.total)
                        self.ingestStatus = "\(progress.message) · \(progress.fileName) · \(progress.completed)/\(progress.total)"
                    }
                }
                guard generation == projectGeneration else { throw CancellationError() }
                addImages(urls: urls)
                ingestProgress = 1
                ingestStatus = "Ingest complete · primary + backup verified"
                hasRecoverableIngest = false
                isIngesting = false
                managedIngestTask = nil
            } catch is CancellationError {
                isIngesting = false
                managedIngestTask = nil
                hasRecoverableIngest = true
                ingestStatus = "Ingest stopped · progress saved"
            } catch {
                isIngesting = false
                managedIngestTask = nil
                hasRecoverableIngest = true
                ingestStatus = "Ingest stopped · \(error.localizedDescription)"
            }
        }
    }

    func stopManagedIngest() {
        guard isIngesting else { return }
        ingestStatus = "Stopping ingest…"
        managedIngestTask?.cancel()
    }

    func refreshRecoverableIngestState() async {
        hasRecoverableIngest = await ManagedIngestService.shared.recoverableJob() != nil
    }
}
