import CryptoKit
import Foundation
import SwiftUI

/// ssh-keyscan is unauthenticated. User must independently compare its SHA256
/// fingerprint with the one on Oracle's console BEFORE accepting it.
@MainActor
final class OracleHostKeyVerifier: ObservableObject {
    @Published private(set) var fingerprint = ""
    @Published private(set) var status = "Check this host's SSH fingerprint before connecting."
    @Published private(set) var working = false
    @Published var independentlyVerified = false
    private var scannedKeyLine = ""
    private var currentHost = ""

    func inspect(host: String) {
        guard !working else { return }
        guard Self.validHost(host) else { status = "Enter an IP or DNS hostname first."; return }
        working = true
        independentlyVerified = false
        fingerprint = ""
        status = "Retrieving the host's advertised SSH key…"
        Task {
            let key = await Task.detached(priority: .utility) { Self.scan(host: host) }.value
            if let key {
                scannedKeyLine = key.0
                currentHost = host
                fingerprint = key.1
                status = "Compare this SHA256 fingerprint with Oracle's console for this VM."
            } else {
                status = "Could not retrieve an ED25519 host key. Confirm SSH port 22 is reachable."
            }
            working = false
        }
    }

    func trust() {
        guard independentlyVerified, !scannedKeyLine.isEmpty, !currentHost.isEmpty else {
            status = "First compare the displayed fingerprint independently using Oracle Console."
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sshFolder = home.appendingPathComponent(".ssh", isDirectory: true)
        let known = sshFolder.appendingPathComponent("known_hosts")
        do {
            try FileManager.default.createDirectory(at: sshFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Reject a pre-existing host entry rather than silently replacing a host key.
            let lookup = Process()
            lookup.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            lookup.arguments = ["-F", currentHost, "-f", known.path]
            lookup.standardOutput = Pipe()
            lookup.standardError = Pipe()
            try lookup.run()
            lookup.waitUntilExit()
            if lookup.terminationStatus == 0 {
                status = "An SSH host key is already trusted for this host. Use Test SSH. If it changed, investigate before replacing it."
                return
            }
            if !FileManager.default.fileExists(atPath: known.path) {
                guard FileManager.default.createFile(atPath: known.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    status = "Cannot create ~/.ssh/known_hosts"; return
                }
            }
            let file = try FileHandle(forWritingTo: known)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data((scannedKeyLine + "\n").utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: known.path)
            status = "Verified SSH key saved. Use Test SSH to connect."
            independentlyVerified = false
        } catch {
            status = "Could not save host key: \(error.localizedDescription)"
        }
    }

    private nonisolated static func validHost(_ s: String) -> Bool {
        !s.isEmpty && s.count < 254 && !s.hasPrefix("-") && s.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
        }
    }

    private nonisolated static func scan(host: String) -> (String, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "10", "-t", "ed25519", host]
        let result = Pipe()
        process.standardOutput = result
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let bytes = result.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1] == "ssh-ed25519",
                  let keyData = Data(base64Encoded: String(parts[2])) else { continue }
            let fingerprintData = SHA256.hash(data: keyData)
            let sha = Data(fingerprintData).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return (String(line), "SHA256:" + sha)
        }
        return nil
    }
}
