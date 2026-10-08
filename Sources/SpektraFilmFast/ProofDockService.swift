import Foundation
import Network
import AppKit
import Darwin

struct ProofPhotoRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    var sourceImageID: UUID
    var sourcePath: String
    var proofPath: String
    var originalFilename: String
    var selected = false
    var isCover = false
}

struct ProofGalleryRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var shortCode: String
    var createdAt: Date
    var maxSelections: Int?
    var password: String
    var finished = false
    var photos: [ProofPhotoRecord]

    var selectedCount: Int { photos.filter(\.selected).count }
}

struct ProofGallerySnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var shortCode: String
    var createdAt: Date
    var maxSelections: Int?
    var finished: Bool
    var photos: [ProofPhotoRecord]
    var lanLink: String
    var publicLink: String?
    var shareRunning: Bool
    var shareError: String?

    var selectedCount: Int { photos.filter(\.selected).count }
}

struct ProofGalleryPhotoSeed: Sendable {
    var id: UUID
    var sourceImageID: UUID
    var sourcePath: String
    var proofPath: String
    var originalFilename: String
}

enum ProofDockError: LocalizedError {
    case galleryNotFound
    case photoNotFound
    case serverUnavailable(String)
    case selectionLocked
    case selectionLimitReached(Int)
    case badPassword

    var errorDescription: String? {
        switch self {
        case .galleryNotFound: "Proof gallery was not found."
        case .photoNotFound: "Proof photo was not found."
        case .serverUnavailable(let reason): "Proof server unavailable: \(reason)"
        case .selectionLocked: "The client has already finished this selection. Reopen or generate a new client link first."
        case .selectionLimitReached(let count): "This gallery allows a maximum of \(count) selections."
        case .badPassword: "Incorrect gallery password."
        }
    }
}

enum ProofDockPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SpektraFilm", isDirectory: true)
            .appendingPathComponent("ProofDock", isDirectory: true)
    }

    static var stateURL: URL { root.appendingPathComponent("state.json") }
    static var galleriesRoot: URL { root.appendingPathComponent("Galleries", isDirectory: true) }
    static var clientPicksRoot: URL { root.appendingPathComponent("Client Picks", isDirectory: true) }

    static func galleryDirectory(_ id: UUID) -> URL { galleriesRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
}

private struct ProofHTTPResponse: Sendable {
    var status: Int = 200
    var contentType = "text/plain; charset=utf-8"
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ value: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> ProofHTTPResponse {
        ProofHTTPResponse(status: status, contentType: contentType, body: Data(value.utf8))
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> ProofHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return ProofHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
}

private struct ProofHTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

private final class ProofHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.spektrafilm.proofdock.http", qos: .userInitiated)
    private var listener: NWListener?
    private let handler: @Sendable (ProofHTTPRequest) async -> ProofHTTPResponse
    private let port: UInt16

    init(port: UInt16, handler: @escaping @Sendable (ProofHTTPRequest) async -> ProofHTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ProofDockError.serverUnavailable("invalid port")
        }
        let listener = try NWListener(using: .tcp, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("ProofDock listener failed: \(error)\n", stderr)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = data
            if let chunk { accumulated.append(chunk) }
            if let request = Self.parseRequest(accumulated) {
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
                return
            }
            if error != nil || isComplete || accumulated.count > 2_097_152 {
                self.send(.text("Bad Request", status: 400), on: connection)
                return
            }
            self.receive(connection, data: accumulated)
        }
    }

    private static func parseRequest(_ data: Data) -> ProofHTTPRequest? {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: marker),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        guard rawTarget.hasPrefix("/"), !rawTarget.contains("\r"), !rawTarget.contains("\n") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard headers[key] == nil else { return nil }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"),
              length >= 0, length <= 2_097_152 else { return nil }
        let bodyStart = headerRange.upperBound
        guard bodyStart <= 65_536, length <= data.count - bodyStart else { return nil }
        let body = length > 0 ? data.subdata(in: bodyStart..<(bodyStart + length)) : Data()
        let components = URLComponents(string: "http://localhost\(rawTarget)")
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return ProofHTTPRequest(
            method: method,
            path: components?.path ?? rawTarget,
            query: query,
            headers: headers,
            body: body
        )
    }

    static func runAuditRegressionTest() -> Bool {
        for length in ["-1", String(Int.max), "999999999999999999999999", "not-a-number"] {
            let request = Data("POST /api/public/test/unlock HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8)
            if parseRequest(request) != nil { return false }
        }
        let duplicate = Data("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8)
        let chunked = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let valid = Data("POST /test?q=yes HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard parseRequest(duplicate) == nil, parseRequest(chunked) == nil,
              let decoded = parseRequest(valid) else { return false }
        return decoded.path == "/test" && decoded.query["q"] == "yes" && decoded.body == Data("{}".utf8)
    }

    private func send(_ response: ProofHTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 423: reason = "Locked"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private actor ProofTunnelManager {
    private var process: Process?
    private var baseURL: String?
    private var lastError: String?
    private var generation = UUID()
    private var pendingOutput = ""

    func start(port: UInt16) throws {
        stop()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            throw ProofDockError.serverUnavailable("macOS SSH client is unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-R", "80:127.0.0.1:\(port)", "nokey@localhost.run"
        ]
        let session = generation
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.consume(text, session: session) }
        }
        process.terminationHandler = { [weak self] task in
            Task { await self?.terminated(status: task.terminationStatus, session: session) }
        }
        try process.run()
        self.process = process
        self.baseURL = nil
        self.lastError = nil
    }

    func stop() {
        generation = UUID()
        pendingOutput = ""
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        baseURL = nil
    }

    func status() -> (running: Bool, url: String?, error: String?) {
        (process?.isRunning == true, baseURL, lastError)
    }

    private func consume(_ fragment: String, session: UUID) {
        guard generation == session else { return }
        pendingOutput = String((pendingOutput + fragment).suffix(20_000))
        let text = pendingOutput
        let pattern = #"https://[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:lhr\.life|localhost\.run)"#
        guard text.localizedCaseInsensitiveContains("tunneled with tls termination"),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return }
        let candidate = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        if !candidate.localizedCaseInsensitiveContains("admin.localhost.run") { baseURL = candidate }
    }

    private func terminated(status: Int32, session: UUID) {
        guard generation == session else { return }
        if status != 0, baseURL == nil { lastError = "Share tunnel exited with status \(status)." }
        process = nil
    }
}

actor ProofDockService {
    static let shared = ProofDockService()
    static let port: UInt16 = 8765

    private var galleries: [ProofGalleryRecord] = []
    private var server: ProofHTTPServer?
    private let tunnel = ProofTunnelManager()
    private var accessTokens: [String: Set<String>] = [:]
    private let fm = FileManager.default

    init() {
        try? fm.createDirectory(at: ProofDockPaths.galleriesRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: ProofDockPaths.clientPicksRoot, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ProofDockPaths.root.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ProofDockPaths.stateURL.path)
        if let data = try? Data(contentsOf: ProofDockPaths.stateURL),
           let decoded = try? JSONDecoder().decode([ProofGalleryRecord].self, from: data) {
            galleries = decoded
        }
    }

    func ensureRunning() throws {
        if server != nil { return }
        let server = ProofHTTPServer(port: Self.port) { [weak self] request in
            guard let self else { return .text("Server unavailable", status: 503) }
            return await self.handle(request)
        }
        try server.start()
        self.server = server
    }

    func snapshots() async -> [ProofGallerySnapshot] {
        let share = await tunnel.status()
        let lanBase = "http://\(Self.localIPAddress()):\(Self.port)"
        return galleries.sorted { $0.createdAt > $1.createdAt }.map { gallery in
            ProofGallerySnapshot(
                id: gallery.id,
                name: gallery.name,
                shortCode: gallery.shortCode,
                createdAt: gallery.createdAt,
                maxSelections: gallery.maxSelections,
                finished: gallery.finished,
                photos: gallery.photos,
                lanLink: "\(lanBase)/g/\(gallery.shortCode)",
                publicLink: share.url.map { "\($0)/g/\(gallery.shortCode)" },
                shareRunning: share.running,
                shareError: share.error
            )
        }
    }

    func createGallery(
        id: UUID,
        name: String,
        maxSelections: Int?,
        password: String,
        photos: [ProofGalleryPhotoSeed]
    ) throws -> UUID {
        try ensureRunning()
        let code = uniqueShortCode()
        let records = photos.enumerated().map { index, seed in
            ProofPhotoRecord(
                id: seed.id,
                sourceImageID: seed.sourceImageID,
                sourcePath: seed.sourcePath,
                proofPath: seed.proofPath,
                originalFilename: seed.originalFilename,
                selected: false,
                isCover: index == 0
            )
        }
        galleries.append(ProofGalleryRecord(
            id: id,
            name: name,
            shortCode: code,
            createdAt: Date(),
            maxSelections: maxSelections.flatMap { $0 > 0 ? $0 : nil },
            password: password,
            finished: false,
            photos: records
        ))
        persist()
        return id
    }

    func deleteGallery(_ id: UUID) {
        guard let gallery = galleries.first(where: { $0.id == id }) else { return }
        galleries.removeAll { $0.id == id }
        accessTokens[gallery.shortCode] = nil
        persist()
        try? fm.removeItem(at: ProofDockPaths.galleryDirectory(id))
    }

    func setCover(galleryID: UUID, photoID: UUID) throws {
        guard let index = galleries.firstIndex(where: { $0.id == galleryID }) else { throw ProofDockError.galleryNotFound }
        guard galleries[index].photos.contains(where: { $0.id == photoID }) else { throw ProofDockError.photoNotFound }
        for photoIndex in galleries[index].photos.indices {
            galleries[index].photos[photoIndex].isCover = galleries[index].photos[photoIndex].id == photoID
        }
        persist()
    }

    func regenerateClientLink(galleryID: UUID) throws {
        guard let index = galleries.firstIndex(where: { $0.id == galleryID }) else { throw ProofDockError.galleryNotFound }
        accessTokens[galleries[index].shortCode] = nil
        galleries[index].shortCode = uniqueShortCode()
        galleries[index].finished = false
        persist()
    }

    func reopenSameLink(galleryID: UUID) throws {
        guard let index = galleries.firstIndex(where: { $0.id == galleryID }) else { throw ProofDockError.galleryNotFound }
        galleries[index].finished = false
        persist()
    }

    func startSharing() async throws {
        try ensureRunning()
        try await tunnel.start(port: Self.port)
    }

    func stopSharing() async { await tunnel.stop() }

    func clientPicks(galleryID: UUID) throws -> [ProofPhotoRecord] {
        guard let gallery = galleries.first(where: { $0.id == galleryID }) else { throw ProofDockError.galleryNotFound }
        return gallery.photos.filter(\.selected)
    }

    func createClientPickSymlinks(galleryID: UUID) throws -> URL {
        guard let gallery = galleries.first(where: { $0.id == galleryID }) else { throw ProofDockError.galleryNotFound }
        let safeName = gallery.name.replacingOccurrences(of: "/", with: "-")
        let dir = ProofDockPaths.clientPicksRoot.appendingPathComponent("\(safeName) - Client Picks", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for photo in gallery.photos where photo.selected {
            let source = URL(fileURLWithPath: photo.sourcePath)
            var destination = dir.appendingPathComponent(source.lastPathComponent)
            var counter = 2
            while fm.fileExists(atPath: destination.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                destination = dir.appendingPathComponent("\(stem)-\(counter).\(source.pathExtension)")
                counter += 1
            }
            try fm.createSymbolicLink(at: destination, withDestinationURL: source)
        }
        return dir
    }

    private func persist() {
        try? fm.createDirectory(at: ProofDockPaths.root, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ProofDockPaths.root.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(galleries) {
            try? data.write(to: ProofDockPaths.stateURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ProofDockPaths.stateURL.path)
        }
    }

    private func uniqueShortCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let used = Set(galleries.map(\.shortCode))
        for _ in 0..<100 {
            let code = String((0..<10).compactMap { _ in alphabet.randomElement() })
            if !used.contains(code) { return code }
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).uppercased()
    }

    private func gallery(code: String) -> ProofGalleryRecord? { galleries.first { $0.shortCode == code } }

    private func isAuthorized(_ gallery: ProofGalleryRecord, request: ProofHTTPRequest) -> Bool {
        guard !gallery.password.isEmpty else { return true }
        let token = request.headers["x-proof-access"] ?? request.query["access"] ?? ""
        return accessTokens[gallery.shortCode]?.contains(token) == true
    }

    private func handle(_ request: ProofHTTPRequest) async -> ProofHTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        if request.method == "GET", parts.count == 2, parts[0] == "g", let gallery = gallery(code: parts[1]) {
            return .text(clientHTML(gallery: gallery, host: request.headers["host"] ?? "127.0.0.1:\(Self.port)"), contentType: "text/html; charset=utf-8")
        }
        if request.method == "GET", parts.count == 3, parts[0] == "cover", let gallery = gallery(code: parts[1]) {
            guard isAuthorized(gallery, request: request) else { return .text("Unauthorized", status: 401) }
            guard let cover = gallery.photos.first(where: \.isCover) ?? gallery.photos.first else { return .text("Not Found", status: 404) }
            return imageResponse(path: cover.proofPath)
        }
        if request.method == "GET", parts.count == 4, parts[0] == "proof", let gallery = gallery(code: parts[1]), let photoID = UUID(uuidString: parts[2]) {
            guard isAuthorized(gallery, request: request), let photo = gallery.photos.first(where: { $0.id == photoID }) else { return .text("Unauthorized", status: 401) }
            return imageResponse(path: photo.proofPath)
        }
        if parts.count >= 4, parts[0] == "api", parts[1] == "public" {
            let code = parts[2]
            guard let gallery = gallery(code: code) else { return .json(["error": "Gallery not found"], status: 404) }
            if request.method == "POST", parts.count == 4, parts[3] == "unlock" {
                struct PasswordBody: Decodable { let password: String }
                let supplied = (try? JSONDecoder().decode(PasswordBody.self, from: request.body).password) ?? ""
                guard supplied == gallery.password else { return .json(["error": "Incorrect password"], status: 401) }
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                // Bound live tokens without invalidating every active client on each unlock.
                if (accessTokens[code]?.count ?? 0) >= 256, let old = accessTokens[code]?.first {
                    accessTokens[code]?.remove(old)
                }
                accessTokens[code, default: []].insert(token)
                return .json(["access": token])
            }
            guard isAuthorized(gallery, request: request) else {
                return .json(["password_required": true], status: 401)
            }
            if request.method == "GET", parts.count == 4, parts[3] == "gallery" {
                return publicGalleryJSON(gallery)
            }
            if request.method == "POST", parts.count == 5, parts[3] == "select", let photoID = UUID(uuidString: parts[4]) {
                do {
                    try toggleSelection(code: code, photoID: photoID)
                    guard let updated = self.gallery(code: code) else { throw ProofDockError.galleryNotFound }
                    return publicGalleryJSON(updated)
                } catch ProofDockError.selectionLocked {
                    return .json(["error": "Selection is locked"], status: 423)
                } catch ProofDockError.selectionLimitReached(let count) {
                    return .json(["error": "You can select up to \(count) photos"], status: 409)
                } catch {
                    return .json(["error": error.localizedDescription], status: 400)
                }
            }
            if request.method == "POST", parts.count == 4, parts[3] == "finish" {
                if let index = galleries.firstIndex(where: { $0.shortCode == code }) {
                    galleries[index].finished = true
                    persist()
                    return .json(["finished": true])
                }
            }
        }
        return .text("Not Found", status: 404)
    }

    private func toggleSelection(code: String, photoID: UUID) throws {
        guard let galleryIndex = galleries.firstIndex(where: { $0.shortCode == code }) else { throw ProofDockError.galleryNotFound }
        guard !galleries[galleryIndex].finished else { throw ProofDockError.selectionLocked }
        guard let photoIndex = galleries[galleryIndex].photos.firstIndex(where: { $0.id == photoID }) else { throw ProofDockError.photoNotFound }
        let currentlySelected = galleries[galleryIndex].photos[photoIndex].selected
        if !currentlySelected, let limit = galleries[galleryIndex].maxSelections,
           galleries[galleryIndex].selectedCount >= limit { throw ProofDockError.selectionLimitReached(limit) }
        galleries[galleryIndex].photos[photoIndex].selected.toggle()
        persist()
    }

    private func publicGalleryJSON(_ gallery: ProofGalleryRecord) -> ProofHTTPResponse {
        struct PublicPhoto: Encodable { var id: String; var filename: String; var selected: Bool; var url: String }
        struct Payload: Encodable { var name: String; var finished: Bool; var selected_count: Int; var max_selections: Int?; var photos: [PublicPhoto] }
        let photos = gallery.photos.map { photo in
            PublicPhoto(id: photo.id.uuidString, filename: photo.originalFilename, selected: photo.selected, url: "/proof/\(gallery.shortCode)/\(photo.id.uuidString)/image.jpg")
        }
        return .json(Payload(name: gallery.name, finished: gallery.finished, selected_count: gallery.selectedCount, max_selections: gallery.maxSelections, photos: photos))
    }

    private func imageResponse(path: String) -> ProofHTTPResponse {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .text("Not Found", status: 404) }
        return ProofHTTPResponse(status: 200, contentType: "image/jpeg", headers: ["Cache-Control": "private, max-age=300"], body: data)
    }

    private func clientHTML(gallery: ProofGalleryRecord, host: String) -> String {
        let scheme = host.contains("localhost.run") || host.contains("lhr.life") ? "https" : "http"
        let absoluteCover = Self.escapeHTML("\(scheme)://\(host)/cover/\(gallery.shortCode)/image.jpg")
        let title = Self.escapeHTML(gallery.name)
        let code = Self.escapeJS(gallery.shortCode)
        let hasPassword = gallery.password.isEmpty ? "false" : "true"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title) — ProofDock</title><meta property="og:title" content="\(title)"><meta property="og:type" content="website"><meta property="og:image" content="\(absoluteCover)">
        <style>\(Self.clientCSS)</style></head><body><header><div><small>CLIENT PROOFS</small><h1 id="title">\(title)</h1></div><div class="pill" id="count">0 selected</div></header><main><div id="gate" class="gate hidden"><div class="gatecard"><small>PRIVATE GALLERY</small><h2>Enter gallery password</h2><input id="pw" type="password" autocomplete="current-password"><button id="unlock">Open Gallery</button><p id="gateError"></p></div></div><div id="submitted" class="submitted hidden">Selection submitted. Your photographer has your picks.</div><div id="grid" class="grid"></div></main><footer><span id="hint">Tap the heart to select. Tap the photo to preview.</span><button id="finish">Finish Selection</button></footer><div id="lightbox" class="lightbox hidden"><button class="backdrop" aria-label="Close preview"></button><div class="stage"><button class="close" aria-label="Close">×</button><img id="big"><div class="meta"><span id="bigName"></span><button id="bigHeart">♡ Select</button></div></div></div>
        <script>
        const code='\(code)', needsPassword=\(hasPassword); let access=sessionStorage.getItem('proof-access-'+code)||'', data=null, active=null;
        const headers=()=>access?{'X-Proof-Access':access}:{}; const api=(path,opt={})=>fetch('/api/public/'+code+path,{...opt,headers:{...headers(),...(opt.headers||{})}});
        async function load(){let r=await api('/gallery');if(r.status===401){gate.classList.remove('hidden');return}if(!r.ok)return;gate.classList.add('hidden');data=await r.json();render()}
        function render(){title.textContent=data.name;count.textContent=data.selected_count+' selected'+(data.max_selections?' / '+data.max_selections:'');submitted.classList.toggle('hidden',!data.finished);finish.disabled=data.finished;grid.innerHTML=data.photos.map(p=>`<article class="card ${p.selected?'selected':''}"><button class="preview" data-id="${p.id}"><img loading="lazy" src="${p.url}?access=${encodeURIComponent(access)}"><span>${esc(p.filename)}</span></button><button class="heart ${p.selected?'on':''}" data-heart="${p.id}" ${data.finished?'disabled':''}>${p.selected?'♥':'♡'}</button></article>`).join('');document.querySelectorAll('[data-heart]').forEach(b=>b.onclick=e=>{e.stopPropagation();toggle(b.dataset.heart)});document.querySelectorAll('.preview').forEach(b=>b.onclick=()=>openBox(b.dataset.id))}
        async function toggle(id){let r=await api('/select/'+id,{method:'POST'});let j=await r.json();if(!r.ok){alert(j.error||'Could not update selection');return}data=j;render();if(active===id)syncBox()}
        finish.onclick=async()=>{if(!confirm('Finish and send these selections to your photographer?'))return;let r=await api('/finish',{method:'POST'});if(r.ok)load()};
        unlock.onclick=async()=>{let r=await fetch('/api/public/'+code+'/unlock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw.value})});let j=await r.json();if(!r.ok){gateError.textContent=j.error||'Incorrect password';return}access=j.access;sessionStorage.setItem('proof-access-'+code,access);load()};pw.onkeydown=e=>{if(e.key==='Enter')unlock.click()};
        function openBox(id){active=id;syncBox();lightbox.classList.remove('hidden');document.body.classList.add('locked')}function syncBox(){let p=data.photos.find(x=>x.id===active);if(!p)return;big.src=p.url+'?access='+encodeURIComponent(access);bigName.textContent=p.filename;bigHeart.textContent=p.selected?'♥ Selected':'♡ Select';bigHeart.classList.toggle('on',p.selected);bigHeart.disabled=data.finished}function closeBox(){lightbox.classList.add('hidden');document.body.classList.remove('locked');active=null}bigHeart.onclick=()=>active&&toggle(active);document.querySelector('.backdrop').onclick=closeBox;document.querySelector('.close').onclick=closeBox;document.onkeydown=e=>{if(e.key==='Escape')closeBox()};
        const esc=s=>String(s).replace(/[&<>\"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',"'":'&#39;'}[c])); if(needsPassword&&!access)gate.classList.remove('hidden');load();setInterval(()=>{if(!data?.finished)load()},5000);
        </script></body></html>
        """
    }

    private static let clientCSS = """
    :root{color-scheme:dark;--bg:#0b0c0d;--panel:#111315;--line:#292c30;--muted:#9da2a8;--text:#f4f5f6}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display',sans-serif}body.locked{overflow:hidden}header{position:sticky;top:0;z-index:20;display:flex;align-items:end;justify-content:space-between;padding:32px max(20px,4vw) 22px;background:rgba(11,12,13,.92);backdrop-filter:blur(18px);border-bottom:1px solid var(--line)}small{font-size:10px;letter-spacing:.16em;color:var(--muted);font-weight:700}h1{margin:5px 0 0;font-size:clamp(25px,4vw,39px);letter-spacing:-.035em}.pill{padding:8px 12px;border:1px solid #363a3f;border-radius:999px;font-size:12px;font-weight:650;color:#d8dadd}main{padding:18px max(8px,2vw) 100px}.grid{columns:5 250px;column-gap:10px}.card{position:relative;break-inside:avoid;margin-bottom:10px;border-radius:7px;overflow:hidden;background:#16181a}.preview{appearance:none;padding:0;border:0;background:transparent;width:100%;display:block;cursor:zoom-in;color:white;text-align:left}.preview img{display:block;width:100%;height:auto;transition:.16s}.preview span{position:absolute;left:8px;bottom:7px;max-width:75%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:10px;padding:4px 6px;border-radius:4px;background:rgba(0,0,0,.54);opacity:0;transition:.15s}.card:hover .preview img{filter:brightness(.86)}.card:hover .preview span{opacity:1}.card.selected{outline:2px solid rgba(255,255,255,.9);outline-offset:-2px}.heart{position:absolute;right:8px;top:8px;width:38px;height:38px;border-radius:50%;border:1px solid rgba(255,255,255,.2);background:rgba(8,9,10,.66);color:white;font-size:20px;display:grid;place-items:center;backdrop-filter:blur(9px);cursor:pointer}.heart.on{background:white;color:#101112}.heart:disabled{opacity:.6}footer{position:fixed;bottom:0;left:0;right:0;z-index:30;padding:12px max(18px,4vw);display:flex;align-items:center;justify-content:space-between;gap:16px;background:rgba(11,12,13,.94);backdrop-filter:blur(18px);border-top:1px solid var(--line);font-size:12px;color:var(--muted)}footer button,.gatecard button{appearance:none;border:0;border-radius:8px;background:white;color:#111;padding:11px 16px;font-weight:750}.submitted{max-width:800px;margin:0 auto 18px;padding:12px 15px;border:1px solid #395445;background:#152219;border-radius:9px;color:#dce9df}.hidden{display:none!important}.gate{position:fixed;inset:0;z-index:70;background:rgba(5,6,7,.96);display:grid;place-items:center;padding:20px}.gatecard{width:min(420px,100%);border:1px solid var(--line);background:#111315;border-radius:15px;padding:27px}.gatecard h2{margin:7px 0 18px}.gatecard input{width:100%;padding:12px;margin-bottom:10px;border:1px solid #3a3d42;border-radius:8px;background:#090a0b;color:white}.gatecard button{width:100%}.gatecard p{color:#d36f69;font-size:12px}.lightbox{position:fixed;inset:0;z-index:90;display:grid;place-items:center;padding:12px}.backdrop{position:absolute;inset:0;border:0;background:rgba(0,0,0,.95);cursor:zoom-out}.stage{position:relative;z-index:1;width:min(96vw,1800px);height:95vh;display:flex;flex-direction:column;align-items:center;justify-content:center;pointer-events:none}.stage img{max-width:100%;max-height:calc(100% - 58px);object-fit:contain;pointer-events:auto}.close{pointer-events:auto;position:absolute;top:5px;right:5px;width:44px;height:44px;border-radius:50%;border:1px solid rgba(255,255,255,.25);background:rgba(10,10,10,.6);color:white;font-size:28px}.meta{pointer-events:auto;width:min(100%,1100px);height:52px;display:flex;align-items:center;justify-content:space-between;gap:14px;font-size:12px}.meta button{border:1px solid rgba(255,255,255,.25);background:#17191b;color:white;border-radius:999px;padding:8px 13px;font-weight:700}.meta button.on{background:white;color:#111}@media(max-width:900px){.grid{columns:3 220px}}@media(max-width:560px){header{padding:20px 16px 15px}.pill{white-space:nowrap}.grid{columns:2 145px;column-gap:7px}.card{margin-bottom:7px}.heart{width:42px;height:42px;right:6px;top:6px}footer{padding:10px 12px}footer span{max-width:55%}}
    """

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeJS(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private static func localIPAddress() -> String {
        var address = "127.0.0.1"
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return address }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let candidate = host.withUnsafeBufferPointer { buffer -> String in
                    guard let base = buffer.baseAddress else { return "" }
                    return String(cString: base)
                }
                if candidate.hasPrefix("192.168.") || candidate.hasPrefix("10.") || candidate.hasPrefix("172.") {
                    return candidate
                }
                address = candidate
            }
        }
        return address
    }
}

enum ProofDockAudit {
    static func run() -> Bool { ProofHTTPServer.runAuditRegressionTest() }
}
