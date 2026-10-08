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
    @Environment(\.dismiss) private var dismiss

    @AppStorage("SpektraFilmStudio.oracle.host") private var host = ""
    @AppStorage("SpektraFilmStudio.oracle.user") private var username = "ubuntu"
    @AppStorage("SpektraFilmStudio.oracle.sshKeyPath") private var sshKeyPath = ""
    @AppStorage("SpektraFilmStudio.oracle.workerPath") private var workerPath = ""
    @AppStorage("SpektraFilmStudio.oracle.transferMode") private var transferMode = "bulk"
    @State private var manifestPath = ""
    @AppStorage("SpektraFilmStudio.oracle.allowedHost") private var approvedCDNHost = ""

    private var configuration: NativeCloudTransferRunner.Configuration {
        .init(host: host, username: username, sshKey: sshKeyPath,
              workerDirectory: workerPath, manifest: manifestPath,
              allowedCDNHost: approvedCDNHost, isBulk: transferMode == "bulk")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CLOUD CONNECTIONS").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Lightroom → Oracle transfer server → iCloud Drive. RAW originals never transfer through this Mac during migration.")
                .font(.subheadline).foregroundStyle(.secondary)

            Form {
                Section("1 · Lightroom") {
                    Text("Lightroom Cloud API requires Adobe-approved partner entitlement. An ordinary Adobe developer app registration is not sufficient to download RAW originals.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Adobe Partner Access") {
                            NSWorkspace.shared.open(URL(string: "https://developer.adobe.com/lightroom/lightroom-api-docs/getting-started/")!)
                        }
                        Button("Choose Adobe Export Manifest…") { selectJSON() }
                        Text(manifestPath.isEmpty ? "No manifest selected" : URL(fileURLWithPath: manifestPath).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Picker("Authorized export", selection: $transferMode) {
                        Text("Adobe bulk archive URLs").tag("bulk")
                        Text("Entitled RAW original URLs").tag("originals")
                    }
                    .pickerStyle(.radioGroup)
                    TextField("Reviewed Adobe download/CDN hostname (optional)", text: $approvedCDNHost)
                        .help("Use only an independently verified domain from your Adobe-generated download URL")
                    Text("Manifest contains authorized signed URLs; it will be copied over SSH to the Oracle VM. Never place it in a public repository.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("2 · Oracle transfer server") {
                    TextField("Public hostname or IP", text: $host)
                    TextField("SSH username", text: $username)
                    HStack {
                        Text(sshKeyPath.isEmpty ? "No SSH private key selected" : URL(fileURLWithPath: sshKeyPath).lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose SSH Key…") { selectKey() }
                    }
                    HStack {
                        Text(workerPath.isEmpty ? "Choose the repository's Tools/OracleTransfer folder" : workerPath)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose Worker Folder…") { selectWorker() }
                    }
                    HStack {
                        Button("Test SSH") { runner.run(.testSSH, configuration: configuration) }
                        Button("Deploy Worker") { runner.run(.deploy, configuration: configuration) }
                        Button("Check iCloud") { runner.run(.checkICloud, configuration: configuration) }
                    }
                    .disabled(runner.running)
                    Text("SSH uses strict host-key checking. Verify the server fingerprint and add the host to your Mac's known_hosts before connecting. Oracle provisioning and Apple's initial iCloud/rclone 2FA must be completed with your own accounts.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("3 · Transfer") {
                    HStack {
                        Button("Validate") { runner.run(.validate, configuration: configuration) }
                        Button("Pilot One Batch") { runner.run(.pilot, configuration: configuration) }
                        Button("Start / Resume Transfer") { runner.run(.migrate, configuration: configuration) }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(runner.running || manifestPath.isEmpty)
                    Text("The VM streams from Adobe-authorized HTTPS originals/archives to iCloud Drive using the repository worker. A transfer can resume after an interrupted session; do not delete Adobe originals until read-back verification and a second backup.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("4 · SpektraFilm library") {
                    HStack {
                        Button("Open iCloud Library…") { model.openICloudLibrary() }
                        Button("Sync Now") { Task { await model.synchronizeCloudNow() } }
                            .disabled(!model.isCloudLibraryConnected)
                        Button("Choose External Scratch…") { model.chooseExternalOriginalScratch() }
                    }
                    Text(model.cloudLibraryStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if runner.running { ProgressView().controlSize(.small) }
                Text(runner.status).font(.caption).foregroundStyle(runner.failed ? Color.red : Color.secondary)
                Spacer()
            }
            ScrollView {
                Text(runner.output.isEmpty ? "Connection and transfer diagnostics will appear here." : runner.output)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(height: 110)
            .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 750, idealWidth: 800, minHeight: 700)
    }

    private func selectJSON() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK { manifestPath = p.url?.path ?? "" }
    }
    private func selectKey() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        if p.runModal() == .OK { sshKeyPath = p.url?.path ?? "" }
    }
    private func selectWorker() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        if p.runModal() == .OK { workerPath = p.url?.path ?? "" }
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
    enum Operation: Sendable { case testSSH, deploy, checkICloud, validate, pilot, migrate }
    @Published var running = false
    @Published var status = "Not connected"
    @Published var output = ""
    @Published var failed = false

    func run(_ operation: Operation, configuration: Configuration) {
        guard !running else { return }
        let host = configuration.host
        let username = configuration.username
        guard Self.safeToken(host, host: true), Self.safeToken(username, host: false),
              FileManager.default.fileExists(atPath: configuration.sshKey) else {
            failed = true
            status = "Provide a valid SSH host, username, and existing SSH key"
            return
        }
        if operation == .deploy {
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: configuration.workerDirectory).appendingPathComponent("transfer.py").path),
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: configuration.workerDirectory).appendingPathComponent("bulk_zip_migrate.py").path) else {
                status = "Select the full Tools/OracleTransfer directory from the checked-out repository"
                failed = true
                return
            }
        }
        if operation == .validate || operation == .pilot || operation == .migrate {
            guard configuration.allowedCDNHost.isEmpty ||
                    (Self.safeToken(configuration.allowedCDNHost, host: true) && configuration.allowedCDNHost.contains(".")) else {
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
                status = response.status == 0 ? "Finished · inspect transfer verification log" : "Failed (exit \\(response.status)) · see details"
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
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
            ($0 >= 97 && $0 <= 122) || $0 == 45 ||
            (host ? $0 == 46 : $0 == 95)
        }
    }

    private struct Response: Sendable { let status: Int32; let output: String }
    private nonisolated static func execute(_ operation: Operation, config: Configuration) throws -> Response {
        let target = "\(config.username)@\(config.host)"
        let ssh = ["-i", config.sshKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                   "-o", "StrictHostKeyChecking=yes"]
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
                options: .regularExpression
            )
            let safe = redactedURLs.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let s = String(line)
                if s.contains("Bearer ") || s.contains("X-Amz-Signature") || s.contains("sig=") || s.contains("token=") { return "[private transfer URL/token redacted]" }
                return s
            }.joined(separator: "\n")
            return Response(status: process.terminationStatus, output: String(safe.suffix(20000)))
        }
        func requireSuccess(_ response: Response) throws {
            if response.status != 0 {
                throw NSError(domain: "SpektraFilm.CloudTransfer", code: Int(response.status),
                              userInfo: [NSLocalizedDescriptionKey: response.output])
            }
        }
        func remote(_ cmd: String) throws -> Response { try run("/usr/bin/ssh", ssh + [target, cmd]) }
        // Shell commands are fixed literals; host/user are validated. No arbitrary
        // manifest-supplied strings are interpolated into a remote command.
        let remoteDir = "$HOME/SpektraFilmWorker"
        switch operation {
        case .testSSH:
            return try remote("printf 'Oracle SSH OK\\n'; uname -s; python3 --version")
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
            return try remote("cd \(remoteDir) && chmod 600 \(name) && python3 -u \(script) \(command) --manifest \(name)\(approvedHostOption)")
        }
    }

    private nonisolated static func requireSuccessOrThrow(_ response: Response) throws {
        if response.status != 0 {
            throw NSError(domain: "SpektraFilm.CloudTransfer", code: Int(response.status),
                          userInfo: [NSLocalizedDescriptionKey: response.output])
        }
    }
}
