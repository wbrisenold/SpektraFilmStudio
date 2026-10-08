import Foundation

enum ExportJobState: String, Codable, Sendable {
    case queued, running, stopping, stopped, completed
}

enum ExportItemState: String, Codable, Sendable {
    case pending, rendering, writing, completed, failed

    var label: String {
        switch self {
        case .pending: "Waiting"
        case .rendering: "Rendering"
        case .writing: "Writing"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "clock"
        case .rendering: "wand.and.stars"
        case .writing: "square.and.arrow.down"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct ExportItemTimings: Codable, Sendable, Equatable {
    var wallMs: Double = 0
    var decodeMs: Double = 0
    var decodePrefetched: Bool = false
    var gradeMs: Double = 0
    var renderMs: Double = 0
    var renderGpuMs: Double = 0
    var renderPassCount: UInt32 = 0
    var geometryResizeMs: Double = 0
    var writeMs: Double = 0
    var sourceWidth: Int = 0
    var sourceHeight: Int = 0
    var outputWidth: Int = 0
    var outputHeight: Int = 0
    var outputBytes: Int64 = 0

    var csvRow: String {
        [
            String(format: "%.1f", wallMs),
            String(format: "%.1f", decodeMs),
            decodePrefetched ? "prefetched" : "inline",
            String(format: "%.1f", gradeMs),
            String(format: "%.1f", renderMs),
            String(format: "%.1f", renderGpuMs),
            String(format: "%u", renderPassCount),
            String(format: "%.1f", geometryResizeMs),
            String(format: "%.1f", writeMs),
            String(format: "%d", sourceWidth),
            String(format: "%d", sourceHeight),
            String(format: "%d", outputWidth),
            String(format: "%d", outputHeight),
            String(format: "%lld", outputBytes)
        ].joined(separator: ",")
    }

    static let csvHeader = "source_file,destination_file,wall_ms,decode_ms,decode_source,grade_ms,render_ms,render_gpu_ms,render_passes,geometry_resize_ms,write_ms,source_w,source_h,output_w,output_h,output_bytes"
}

struct ExportQueueItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sourceImageID: UUID
    let sourcePath: String
    let sourceFileName: String
    let destinationPath: String
    let look: RenderLook
    var state: ExportItemState
    var errorMessage: String?
    var outputBytes: Int64?
    var timings: ExportItemTimings?

    init(image: ProjectImageRecord, destination: URL) {
        id = UUID()
        sourceImageID = image.id
        sourcePath = image.sourcePath
        sourceFileName = image.fileName
        destinationPath = destination.path
        look = image.look
        state = .pending
        errorMessage = nil
        outputBytes = nil
        timings = nil
    }
}

struct ExportJob: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let settings: ExportSettings
    let bypassImportTransform: Bool
    var state: ExportJobState
    var items: [ExportQueueItem]

    init(settings: ExportSettings, bypassImportTransform: Bool, items: [ExportQueueItem]) {
        id = UUID()
        createdAt = Date()
        updatedAt = createdAt
        self.settings = settings
        self.bypassImportTransform = bypassImportTransform
        state = .queued
        self.items = items
    }

    var completedCount: Int { items.lazy.filter { $0.state == .completed }.count }
    var failedCount: Int { items.lazy.filter { $0.state == .failed }.count }
    var processedCount: Int { completedCount + failedCount }
    var remainingCount: Int { items.count - completedCount }
    var fractionComplete: Double {
        guard !items.isEmpty else { return 0 }
        return Double(processedCount) / Double(items.count)
    }

    // Absolute ceiling. Large full-resolution frames are dynamically limited to one.
    static let postProcessWorkerCount = 2

    var estimatedRemainingSeconds: Double? {
        let samples = items.compactMap(\.timings).filter { $0.wallMs > 0 }
        guard !samples.isEmpty else { return nil }

        func mean(_ values: [Double]) -> Double {
            values.reduce(0, +) / Double(max(1, values.count))
        }

        let decodeLaneMs = mean(samples.map(\.decodeMs))
        let renderLaneMs = mean(
            samples.map { $0.gradeMs + $0.renderMs }
        )
        let postLaneMs =
            mean(samples.map { $0.geometryResizeMs + $0.writeMs }) /
            Double(Self.postProcessWorkerCount)

        let throughputMs = max(
            1,
            max(decodeLaneMs, max(renderLaneMs, postLaneMs))
        )
        let unfinished = items.lazy.filter {
            $0.state != .completed && $0.state != .failed
        }.count

        let drainMs =
            unfinished > 0
            ? mean(samples.map { $0.geometryResizeMs + $0.writeMs }) /
              Double(Self.postProcessWorkerCount)
            : 0

        return (throughputMs * Double(unfinished) + drainMs) / 1000.0
    }

    var estimatedTotalOutputBytes: Int64? {
        let samples = items.compactMap { item -> Int64? in
            guard item.state == .completed, let bytes = item.outputBytes, bytes > 0 else { return nil }
            return bytes
        }
        guard !samples.isEmpty else { return nil }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let estimate = (mean * Double(items.count)).rounded()
        guard estimate.isFinite, estimate >= 0, estimate < Double(Int64.max) else { return nil }
        return Int64(estimate)
    }

    mutating func normalizeAfterInterruptedLaunch() {
        let fm = FileManager.default
        for index in items.indices {
            switch items[index].state {
            case .completed:
                if !fm.fileExists(atPath: items[index].destinationPath) {
                    items[index].state = .pending
                    items[index].outputBytes = nil
                }
            case .rendering:
                items[index].state = .pending
                items[index].errorMessage = nil
            case .writing:
                // The writer never overwrites an existing path, and the planner reserved this
                // destination before the job began. A non-empty final file therefore means the
                // atomic commit completed before the crash even if the next journal write did not.
                if let attrs = try? fm.attributesOfItem(atPath: items[index].destinationPath),
                   let size = attrs[.size] as? NSNumber,
                   size.int64Value > 0 {
                    items[index].state = .completed
                    items[index].outputBytes = size.int64Value
                    items[index].errorMessage = nil
                } else {
                    items[index].state = .pending
                    items[index].errorMessage = nil
                }
            case .pending, .failed:
                break
            }
        }
        state = completedCount == items.count ? .completed : .stopped
        updatedAt = Date()
    }
}

enum ExportPlanningError: LocalizedError {
    case noImages
    case noDestination
    case invalidSequence

    var errorDescription: String? {
        switch self {
        case .noImages: "No photos are selected for export."
        case .noDestination: "Choose an export destination first."
        case .invalidSequence: "Export sequence must be positive and fit all selected photos."
        }
    }
}

enum ExportJobPlanner {
    static func makeJob(
        images: [ProjectImageRecord],
        settings: ExportSettings,
        bypassImportTransform: Bool
    ) throws -> ExportJob {
        guard !images.isEmpty else { throw ExportPlanningError.noImages }
        guard !settings.destinationPath.isEmpty else { throw ExportPlanningError.noDestination }

        guard settings.sequenceStart >= 1,
              !settings.sequenceStart.addingReportingOverflow(images.count - 1).overflow else {
            throw ExportPlanningError.invalidSequence
        }
        let directory = URL(fileURLWithPath: settings.destinationPath, isDirectory: true)
        let fm = FileManager.default
        var reserved = Set<String>()
        var items: [ExportQueueItem] = []
        items.reserveCapacity(images.count)

        for (offset, image) in images.enumerated() {
            let sequence = settings.sequenceStart + offset
            let stem = safeStem(image: image, sequence: sequence, settings: settings, batchCount: images.count)
            var destination = directory
                .appendingPathComponent(stem)
                .appendingPathExtension(settings.format.fileExtension)

            let originalStem = destination.deletingPathExtension().lastPathComponent
            var collision = 2

            while reserved.contains(normalized(destination)) || fm.fileExists(atPath: destination.path) {
                destination = directory
                    .appendingPathComponent("\(originalStem)_\(collision)")
                    .appendingPathExtension(settings.format.fileExtension)
                collision += 1
            }

            reserved.insert(normalized(destination))
            items.append(ExportQueueItem(image: image, destination: destination))
        }
        return ExportJob(
            settings: settings,
            bypassImportTransform: bypassImportTransform,
            items: items
        )
    }

    static func previewNames(images: [ProjectImageRecord], settings: ExportSettings, limit: Int = 5) -> [String] {
        guard let job = try? makeJob(
            images: images,
            settings: settings,
            bypassImportTransform: false
        ) else { return [] }
        return Array(job.items.prefix(max(0, limit))).map {
            URL(fileURLWithPath: $0.destinationPath).lastPathComponent
        }
    }

    private static func safeStem(
        image: ProjectImageRecord,
        sequence: Int,
        settings: ExportSettings,
        batchCount: Int
    ) -> String {
        let base = image.url.deletingPathExtension().lastPathComponent
        let sequenceText = String(format: "%04lld", Int64(sequence))
        let template = settings.filenameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = template.isEmpty ? "{name}" : template

        let hasName = effective.contains("{name}") || effective.contains("{original_filename}")
        let hasSequence = effective.contains("{sequence}")
        var expanded = effective
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{original_filename}", with: base)
            .replacingOccurrences(of: "{sequence}", with: sequenceText)

        // A title like "Wedding" is a valid batch title. It can never mean "one destination".
        if batchCount > 1 && !hasName && !hasSequence {
            expanded += "_\(sequenceText)"
        }

        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        let safe = expanded.components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "SpektraFilmStudio_\(sequenceText)" : safe
    }

    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}

actor ExportJobJournal {
    static let shared = ExportJobJournal()

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpektraFilm/ExportJobs", isDirectory: true)
    }

    private var activeURL: URL { directory.appendingPathComponent("active-export.json") }

    func save(_ job: ExportJob) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(job).write(to: activeURL, options: .atomic)
    }

    func load() -> ExportJob? {
        guard let data = try? Data(contentsOf: activeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExportJob.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: activeURL)
    }
}

actor ExportTimingLog {
    static let shared = ExportTimingLog()

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpektraFilm/ExportTimings/timings.csv")
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func record(_ item: ExportQueueItem) {
        guard let timings = item.timings else { return }
        let row = [
            Self.csvField(item.sourceFileName),
            Self.csvField((item.destinationPath as NSString).lastPathComponent),
            timings.csvRow
        ].joined(separator: ",")

        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: Self.fileURL.path)
        do {
            try fm.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if isNew {
                try (ExportItemTimings.csvHeader + "\n" + row + "\n")
                    .write(to: Self.fileURL, atomically: true, encoding: .utf8)
            } else if let handle = try? FileHandle(forWritingTo: Self.fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((row + "\n").utf8))
            }
        } catch {
            print("SpektraFilm: export timing log unavailable: \(error.localizedDescription)")
        }
    }

    func url() -> URL { Self.fileURL }
}
