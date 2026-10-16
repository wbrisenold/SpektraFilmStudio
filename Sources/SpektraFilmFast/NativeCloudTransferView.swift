import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// In-app orchestration of the existing OracleTransfer Python transfer worker.
/// The Mac uploads a *manifest*, never the user's 2 TB of RAW originals.
/// SSH keys remain on the Mac and Adobe credentials are never entered here.
struct NativeCloudTransferView: View {
    @ObservedObject var model: AppModel
    @StateObject private var runner = NativeCloudTransferRunner()
    var body: some View {
        CloudSetupWizard(model: model, runner: runner)
    }
}

@MainActor
final class NativeCloudTransferRunner: ObservableObject {
    struct Configuration: Sendable {
        let host: String
        let username: String
        let sshKey: String
        let workerDirectory: String
        let manifest: String
        let allowedCDNHost: String
        let isBulk: Bool
    }

    enum Operation: Sendable { case testSSH, installRclone, deploy, checkICloud, validate, pilot, migrate }
    @Published var running = false
    @Published var status = "Not connected"
    @Published var output = ""
    @Published var failed = false

    func run(_ operation: Operation, configuration: Configuration) {
        guard !running else { return }
        let host = configuration.host
        let username = configuration.username
        // Validate SSH key path to prevent path traversal attacks
        let standardizedKeyPath = URL(fileURLWithPath: configuration.sshKey).standardizedFileURL.path
        guard Self.safeToken(host, host: true), Self.safeToken(username, host: false),
              FileManager.default.fileExists(atPath: standardizedKeyPath)
        else {
            failed = true
            status = "Provide a valid SSH host, username, and existing SSH key"
            return
        }
        if operation == .deploy {
            guard
                FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: configuration.workerDirectory).appendingPathComponent("transfer.py")
                        .path,
                ),
                FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: configuration.workerDirectory).appendingPathComponent(
                        "bulk_zip_migrate.py",
                    ).path,
                )
            else {
                status = "Select the full Tools/OracleTransfer directory from the checked-out repository"
                failed = true
                return
            }
        }
        if operation == .validate || operation == .pilot || operation == .migrate {
            guard
                configuration.allowedCDNHost.isEmpty
                || (Self.safeToken(configuration.allowedCDNHost, host: true)
                    && configuration.allowedCDNHost.contains("."))
            else {
                status = "Review and enter a valid Adobe download/CDN hostname"
                failed = true
                return
            }
            guard FileManager.default.fileExists(atPath: configuration.manifest) else {
                status = "Select an authorized JSON manifest"
                failed = true
                return
            }
        }
        running = true
        failed = false
        status = "Running secure Oracle operation…"
        output = ""
        Task {
            do {
                let response = try await Task.detached(priority: .utility) {
                    try Self.execute(operation, config: configuration)
                }.value
                output = response.output
                failed = response.status != 0
                status =
                    response.status == 0
                        ? "Finished · inspect transfer verification log" : "Failed (exit \(response.status)) · see details"
            } catch {
                failed = true
                status = error.localizedDescription
            }
            running = false
        }
    }

    private nonisolated static func safeToken(_ s: String, host: Bool) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-") else { return false }
        return s.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45
                || (host ? $0 == 46 : $0 == 95)
        }
    }

    private struct Response: Sendable { let status: Int32; let output: String }
    private nonisolated static func execute(_ operation: Operation, config: Configuration) throws -> Response {
        let target = "\(config.username)@\(config.host)"
        // Validate SSH key path to prevent path traversal attacks
        let standardizedKeyPath = URL(fileURLWithPath: config.sshKey).standardizedFileURL.path
        let ssh = [
            "-i", standardizedKeyPath, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        func run(_ executable: String, _ args: [String]) throws -> Response {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Avoid accidentally displaying signed Adobe download URLs / auth tokens.
            let raw = String(decoding: bytes, as: UTF8.self)
            let redactedURLs = raw.replacingOccurrences(
                of: #"https?://[^\s]+"#, with: "[transfer URL redacted]",
                options: .regularExpression,
            )
            let safe = redactedURLs.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let s = String(line)
                if s.contains("Bearer ") || s.contains("X-Amz-Signature") || s.contains("sig=") || s.contains("token=") {
                    return "[private transfer URL/token redacted]"
                }
                return s
            }.joined(separator: "\n")
            return Response(status: process.terminationStatus, output: String(safe.suffix(20000)))
        }
        func requireSuccess(_ response: Response) throws {
            if response.status != 0 {
                throw NSError(
                    domain: "SpektraFilm.CloudTransfer", code: Int(response.status),
                    userInfo: [NSLocalizedDescriptionKey: response.output],
                )
            }
        }
        func remote(_ cmd: String) throws -> Response {
            try run("/usr/bin/ssh", ssh + [target, cmd])
        }
        // Shell commands are fixed literals; host/user are validated. No arbitrary
        // manifest-supplied strings are interpolated into a remote command.
        let remoteDir = "$HOME/SpektraFilmWorker"
        switch operation {
        case .testSSH:
            return try remote("printf 'Oracle SSH OK\\n'; uname -s; python3 --version")
        case .installRclone:
            // User-approved install of pinned rclone 1.69.2 binary with SHA256 verification.
            // Downloads the specific macOS binary for the remote architecture and verifies integrity.
            // SECURITY: Pin binary hash to prevent supply chain compromise.
            // rclone 1.69.2 macOS AMD64: 0a9a107ba911bf6bd3c61ad5160a379ac7c81a1b63498e12efcccb4676c65361
            // rclone 1.69.2 macOS ARM64: 826b0fcded05779cf2be1bafebc4382758d2bc6ca869841a9939ec4c2490375e
            return try remote(
                """
                bash -lc 'set -eo pipefail; \
                ARCH=$(uname -m); \
                if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then \
                    URL="https://github.com/rclone/rclone/releases/download/v1.69.2/rclone-v1.69.2-osx-arm64.zip"; \
                    EXPECTED_SHA256="826b0fcded05779cf2be1bafebc4382758d2bc6ca869841a9939ec4c2490375e"; \
                else \
                    URL="https://github.com/rclone/rclone/releases/download/v1.69.2/rclone-v1.69.2-osx-amd64.zip"; \
                    EXPECTED_SHA256="0a9a107ba911bf6bd3c61ad5160a379ac7c81a1b63498e12efcccb4676c65361"; \
                fi; \
                TMPDIR=$(mktemp -d); \
                cd "$TMPDIR"; \
                curl -fsSL "$URL" -o rclone.zip; \
                ACTUAL_SHA256=$(shasum -a 256 rclone.zip | cut -d" " -f1); \
                if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then \
                    echo "SHA256 mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256"; \
                    exit 1; \
                fi; \
                unzip -q rclone.zip; \
                sudo -n mv rclone-v1.69.2-osx-*/rclone /usr/local/bin/rclone; \
                sudo -n chown root:wheel /usr/local/bin/rclone; \
                sudo -n chmod 755 /usr/local/bin/rclone; \
                rclone version'
                """,
            )
        case .deploy:
            try requireSuccess(remote("mkdir -p \(remoteDir); chmod 700 \(remoteDir)"))
            let root = URL(fileURLWithPath: config.workerDirectory)
            var messages = [String]()
            for filename in ["transfer.py", "bulk_zip_migrate.py", "oracle-check.sh"] {
                let file = root.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let response = try run("/usr/bin/scp", ssh + [file.path, "\(target):SpektraFilmWorker/\(filename)"])
                try requireSuccess(response)
                messages.append(filename)
            }
            try requireSuccess(remote("chmod 700 \(remoteDir)/oracle-check.sh; chmod 600 \(remoteDir)/*.py"))
            return Response(status: 0, output: "Deployed: " + messages.joined(separator: ", "))
        case .checkICloud:
            return try remote("cd \(remoteDir) && ./oracle-check.sh")
        case .validate, .pilot, .migrate:
            let local = config.manifest
            let suffix = config.isBulk ? "bulk" : "original"
            let remoteManifest = "SpektraFilmWorker/manifest-\(suffix).json"
            let put = try run("/usr/bin/scp", ssh + [local, "\(target):\(remoteManifest)"])
            try requireSuccess(put)
            let script = config.isBulk ? "bulk_zip_migrate.py" : "transfer.py"
            let name = config.isBulk ? "manifest-bulk.json" : "manifest-original.json"
            let command = operation == .validate ? "validate" : operation == .pilot ? "pilot" : "migrate"
            let approvedHostOption = config.allowedCDNHost.isEmpty ? "" : " --allowed-host \(config.allowedCDNHost)"
            return try remote(
                "cd \(remoteDir) && chmod 600 \(name) && python3 -u \(script) \(command) --manifest \(name)\(approvedHostOption)",
            )
        }
    }

    private nonisolated static func requireSuccessOrThrow(_ response: Response) throws {
        if response.status != 0 {
            throw NSError(
                domain: "SpektraFilm.CloudTransfer", code: Int(response.status),
                userInfo: [NSLocalizedDescriptionKey: response.output],
            )
        }
    }
}
