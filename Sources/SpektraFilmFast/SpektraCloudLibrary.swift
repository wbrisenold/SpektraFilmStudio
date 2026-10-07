import Foundation

/// iCloud/File Provider foundation. Files are streamed in bounded chunks so SpektraFilm
/// does not require a full-size staging duplicate before writing to iCloud Drive.
actor SpektraCloudLibrary {
    enum CloudError: LocalizedError {
        case iCloudUnavailable, createFailed, streamOpenFailed, readFailed, writeFailed
        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable: "iCloud Drive is not available for SpektraFilm."
            case .createFailed: "Could not create the iCloud destination."
            case .streamOpenFailed: "Could not open the cloud transfer stream."
            case .readFailed: "Cloud source read failed."
            case .writeFailed: "iCloud destination write failed."
            }
        }
    }

    let containerIdentifier: String?
    init(containerIdentifier: String? = nil) { self.containerIdentifier = containerIdentifier }

    func containerURL() throws -> URL {
        guard let url = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            throw CloudError.iCloudUnavailable
        }
        return url
    }

    func originalsRoot() throws -> URL {
        let root = try containerURL()
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("SpektraFilm Library", isDirectory: true)
            .appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func materialize(_ url: URL) throws { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
    func evictLocalBytes(_ url: URL) throws { try FileManager.default.evictUbiquitousItem(at: url) }

    func streamCopy(from source: URL, to destination: URL, bufferSize: Int = 8 * 1024 * 1024,
                    progress: (@Sendable (Int64) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw CloudError.createFailed }
        guard let input = InputStream(url: source), let output = OutputStream(url: destination, append: false) else {
            throw CloudError.streamOpenFailed
        }
        input.open(); output.open()
        defer { input.close(); output.close() }

        var buffer = [UInt8](repeating: 0, count: max(64 * 1024, bufferSize))
        var total: Int64 = 0
        while true {
            let read = input.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw input.streamError ?? CloudError.readFailed }
            if read == 0 { break }
            var offset = 0
            while offset < read {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return output.write(base.advanced(by: offset), maxLength: read - offset)
                }
                if written <= 0 { throw output.streamError ?? CloudError.writeFailed }
                offset += written
                total += Int64(written)
                progress?(total)
            }
        }
    }
}
