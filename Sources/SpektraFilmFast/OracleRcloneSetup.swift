import Foundation
import SwiftUI

/// Connects to the user's OWN Oracle VM with a PTY. All submitted passwords/2FA
/// remain in memory only; never use CLI arguments or preferences for secrets.
@MainActor
final class OracleRcloneTerminal: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var output = ""
    private var process: Process?
    private var input: Pipe?
    private var privateValues: [String] = []
    private var pendingPrivateSuffix = ""
    private var generation = UUID()
    private var readTask: Task<Void, Never>?

    func start(configuration: NativeCloudTransferRunner.Configuration) {
        guard !running else { return }
        guard Self.safeHost(configuration.host), Self.safeUser(configuration.username),
              FileManager.default.fileExists(atPath: configuration.sshKey) else {
            output = "Enter a valid Oracle host, SSH username and local private-key path first."
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-tt", "-i", configuration.sshKey,
                          "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                          "-o", "ConnectTimeout=15", "\(configuration.username)@\(configuration.host)",
                          "umask 077; exec rclone config"]
        let outgoing = Pipe(), incoming = Pipe()
        task.standardOutput = outgoing
        task.standardError = outgoing
        task.standardInput = incoming
        do { try task.run() } catch {
            output = "SSH could not start: \(error.localizedDescription)"
            return
        }
        let session = UUID()
        generation = session
        process = task
        input = incoming
        privateValues = []
        pendingPrivateSuffix = ""
        output = "Oracle SSH session started. rclone prompts will appear below.\n"
        running = true
        // Read on a worker. Do not block SwiftUI while waiting for rclone's 2FA prompt.
        readTask = Task.detached(priority: .utility) { [weak self] in
            let reader = outgoing.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                let fragment = String(decoding: data, as: UTF8.self)
                await self?.append(fragment, session: session)
            }
            task.waitUntilExit()
            await self?.finished(code: task.terminationStatus, session: session)
        }
    }

    func send(_ value: String, privateInput: Bool) {
        guard running, let input else { return }
        if privateInput, !value.isEmpty { privateValues.append(value) }
        // stdin only; secrets never become process arguments or logs.
        var data = Data(value.utf8)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { stop(); output += "\nOracle input connection closed." }
    }

    func stop() {
        generation = UUID()
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        input?.fileHandleForWriting.closeFile()
        running = false
        process = nil
        input = nil
        privateValues.removeAll()
        pendingPrivateSuffix = ""
    }

    private func append(_ fragment: String, session: UUID) {
        guard generation == session else { return }
        // Filtering after concatenation catches secrets spanning read boundaries.
        var combined = output + pendingPrivateSuffix + fragment
        pendingPrivateSuffix = ""
        for value in privateValues where !value.isEmpty {
            combined = combined.replacingOccurrences(of: value, with: "[private response hidden]")
        }
        // Some rclone versions echo config fields after login. Hide credential
        // values while retaining plain prompts such as "password>" and "2FA>".
        combined = combined.replacingOccurrences(
            of: #"(?im)^.*(?:cookies|trust_token|password)\s*[:=].*$"#,
            with: "[rclone credential hidden]", options: .regularExpression)
        // Do not publish a partial password echo while waiting for the next read.
        var withheld = 0
        for value in privateValues where value.count > 1 {
            for count in 1..<min(value.count, combined.count + 1) {
                if combined.hasSuffix(value.prefix(count)) { withheld = max(withheld, count) }
            }
        }
        if withheld > 0 {
            pendingPrivateSuffix = String(combined.suffix(withheld))
            combined.removeLast(withheld)
        }
        output = String(combined.suffix(10000))
    }

    private func finished(code: Int32, session: UUID) {
        guard generation == session else { return }
        running = false
        process = nil
        input = nil
        privateValues.removeAll()
        pendingPrivateSuffix = ""
        output += "\nOracle rclone setup exited with code \(code). Test iCloud to confirm the connection."
    }

    static func runAuditRegressionTest() -> Bool {
        let terminal = OracleRcloneTerminal()
        let old = terminal.generation
        terminal.stop()
        terminal.running = true
        terminal.output = "New session"
        terminal.privateValues = ["secret"]
        terminal.append("secret", session: old)
        terminal.finished(code: 1, session: old)
        guard terminal.running, terminal.output == "New session" else { return false }
        terminal.append(" sec", session: terminal.generation)
        guard !terminal.output.contains("sec") else { return false }
        terminal.append("ret", session: terminal.generation)
        return !terminal.output.contains("secret") && terminal.output.contains("hidden")
    }

    private static func safeHost(_ s: String) -> Bool {
        !s.isEmpty && s.count < 254 && !s.hasPrefix("-") && s.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
        }
    }
    private static func safeUser(_ s: String) -> Bool {
        !s.isEmpty && s.count < 65 && !s.hasPrefix("-") && s.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Optional path for existing rclone credentials. This sends the exact config via
/// encrypted SSH, with restrictive permissions, and never displays file contents.
@MainActor
final class OracleRcloneConfigImporter: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var failed = false
    @Published private(set) var status = "No credentials imported"

    func install(localPath: String, configuration: NativeCloudTransferRunner.Configuration) {
        guard !running else { return }
        guard FileManager.default.fileExists(atPath: localPath) else {
            failed = true; status = "Choose an existing rclone.conf first"; return
        }
        guard let text = try? String(contentsOfFile: localPath, encoding: .utf8),
              text.range(of: #"(?m)^\[icloud\]\s*$"#, options: .regularExpression) != nil,
              text.range(of: #"(?m)^\s*type\s*=\s*iclouddrive\s*$"#, options: .regularExpression) != nil else {
            failed = true; status = "File must contain an [icloud] remote of type iclouddrive"; return
        }
        guard !configuration.host.isEmpty, configuration.host.count < 254, !configuration.host.hasPrefix("-"),
              !configuration.username.isEmpty, configuration.username.count < 65, !configuration.username.hasPrefix("-"),
              configuration.host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              configuration.username.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              FileManager.default.fileExists(atPath: configuration.sshKey) else {
            failed = true; status = "Enter the Oracle host, SSH username and SSH key first"; return
        }
        running = true
        failed = false
        status = "Copying encrypted SSH credentials to Oracle…"
        Task {
            let outcome = await Task.detached(priority: .utility) {
                Self.upload(path: localPath, configuration: configuration)
            }.value
            failed = !outcome
            status = outcome ? "Credentials installed. Select Test iCloud to verify the login." : "Credential import failed. Check your SSH connection and Oracle user permissions."
            running = false
        }
    }

    private nonisolated static func upload(path: String, configuration: NativeCloudTransferRunner.Configuration) -> Bool {
        let target = "\(configuration.username)@\(configuration.host)"
        let sshOptions = ["-i", configuration.sshKey, "-o", "BatchMode=yes",
                          "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15"]
        func execute(_ program: String, _ args: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice // Drain without retaining secrets.
            process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit() }
            catch { return false }
            return process.terminationStatus == 0
        }
        guard execute("/usr/bin/ssh", sshOptions + [target, "set -e; umask 077; mkdir -p ~/.config/rclone; chmod 700 ~/.config/rclone"]) else { return false }
        // Remote scratch path is in the authenticated user's home, never a shared /tmp.
        guard execute("/usr/bin/scp", sshOptions + [path, "\(target):.config/rclone/rclone.conf.spektrafilm-new"]) else { return false }
        // Atomic replacement after a complete upload. Existing remote config is backed up.
        return execute("/usr/bin/ssh", sshOptions + [target,
            "set -e; umask 077; chmod 600 ~/.config/rclone/rclone.conf.spektrafilm-new; " +
            "if test -e ~/.config/rclone/rclone.conf; then cp ~/.config/rclone/rclone.conf ~/.config/rclone/rclone.conf.spektrafilm-backup; chmod 600 ~/.config/rclone/rclone.conf.spektrafilm-backup; fi; " +
            "mv ~/.config/rclone/rclone.conf.spektrafilm-new ~/.config/rclone/rclone.conf"])
    }
}
