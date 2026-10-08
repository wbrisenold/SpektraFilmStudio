import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Guided cloud setup. No passwords, Apple tokens, signed URLs or 2FA codes are
/// written to UserDefaults or included in application logs.
struct CloudSetupWizard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runner: NativeCloudTransferRunner
    @StateObject private var terminal = OracleRcloneTerminal()
    @StateObject private var importer = OracleRcloneConfigImporter()
    @StateObject private var hostKey = OracleHostKeyVerifier()
    @Environment(\.dismiss) private var dismiss

    @AppStorage("SpektraFilmStudio.oracle.host") private var host = ""
    @AppStorage("SpektraFilmStudio.oracle.user") private var username = "ubuntu"
    @AppStorage("SpektraFilmStudio.oracle.sshKeyPath") private var sshKeyPath = ""
    @AppStorage("SpektraFilmStudio.oracle.workerPath") private var workerPath = ""
    @AppStorage("SpektraFilmStudio.oracle.transferMode") private var transferMode = "bulk"
    @AppStorage("SpektraFilmStudio.oracle.allowedHost") private var allowedHost = ""

    @State private var step = 0
    @State private var manifestPath = ""
    @State private var rcloneConfigPath = ""
    @State private var publicResponse = ""
    @State private var secretResponse = ""
    @State private var confirmedRemoteCredentialStorage = false

    private let steps: [(name: String, symbol: String)] = [
        ("Mac iCloud", "icloud"),
        ("Oracle", "server.rack"),
        ("Oracle iCloud", "lock.icloud"),
        ("Lightroom", "photo.on.rectangle"),
        ("Transfer", "arrow.left.arrow.right")
    ]

    private var config: NativeCloudTransferRunner.Configuration {
        .init(host: host, username: username, sshKey: sshKeyPath,
              workerDirectory: workerPath, manifest: manifestPath,
              allowedCDNHost: allowedHost, isBulk: transferMode == "bulk")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect your cloud library")
                        .font(.title2.weight(.semibold))
                    Text("Set up one step at a time. You can come back without losing your settings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button("Close") { terminal.stop(); dismiss() }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { index in
                        Button { step = index } label: {
                            Label(steps[index].name, systemImage: steps[index].symbol)
                                .font(.caption.weight(index == step ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 9)
                                .frame(minWidth: 104)
                                .background(index == step ? StudioPalette.selected : StudioPalette.recessed,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(index == step ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    switch step {
                    case 0: localICloudStep
                    case 1: oracleStep
                    case 2: remoteICloudStep
                    case 3: lightroomStep
                    default: transferStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            HStack(spacing: 10) {
                if runner.running { ProgressView().controlSize(.small) }
                Text(runner.status)
                    .font(.caption)
                    .foregroundStyle(runner.failed ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
                Button("Back") { step = max(0, step - 1) }.disabled(step == 0)
                Button(step == steps.count - 1 ? "Done" : "Next") {
                    if step < steps.count - 1 { step += 1 } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 720, idealWidth: 840, minHeight: 620, idealHeight: 780)
        .onAppear {
            if workerPath.isEmpty {
                let preferred = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/SpektraFilmStudio-v0.6.8-Cloud-UX/Tools/OracleTransfer")
                if FileManager.default.fileExists(atPath: preferred.appendingPathComponent("transfer.py").path) {
                    workerPath = preferred.path
                }
            }
        }
    }

    private var localICloudStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Your iCloud Drive on this Mac", caption: "Apple signs you in through macOS. There is no separate iCloud Drive API token for an ordinary personal Drive folder.")
            Label(FileManager.default.ubiquityIdentityToken == nil
                  ? "No macOS iCloud identity detected. Sign in under System Settings → Apple Account → iCloud."
                  : "macOS iCloud account detected.",
                  systemImage: FileManager.default.ubiquityIdentityToken == nil ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open iCloud Library…") { model.openICloudLibrary() }
                Button("Move Current Library…") { model.moveCurrentLibraryToICloud() }
                    .disabled(model.project.images.isEmpty || model.isCloudLibraryConnected)
                Button("Sync Now") { Task { await model.synchronizeCloudNow() } }
                    .disabled(!model.isCloudLibraryConnected)
            }
            Text(model.cloudLibraryStatus).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Temporary RAW editing files").font(.headline)
            Text("Select an external drive for RAW scratch. macOS may still cache iCloud File Provider originals on the internal disk; this cannot be guaranteed away by an app preference.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose External Scratch Drive…") { model.chooseExternalOriginalScratch() }
            Text("For a direct server-side Lightroom migration, continue to Oracle. The originals do not have to transfer through your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var oracleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Connect your Oracle transfer server", caption: "The server downloads authorized originals and uploads them to iCloud Drive. Your Mac only controls the transfer.")
            instructions([
                "Create an Oracle Cloud account and choose an Always Free eligible compute instance in your home region.",
                "During VM creation, add your SSH public key. Allow SSH (TCP 22) only from trusted networks where possible.",
                "Copy its public IP/hostname and select the matching SSH private key below.",
                "Install a current rclone release and Python 3 on the VM before configuring iCloud."
            ])
            Link("Open Oracle Cloud Console", destination: URL(string: "https://cloud.oracle.com/")!)
            Link("Oracle Always Free guide", destination: URL(string: "https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm")!)
            VStack(alignment: .leading, spacing: 8) {
                field("VM public IP or hostname", text: $host)
                field("SSH username", text: $username)
                fileChoice("SSH private key", current: sshKeyPath) { selectSetupFile("ssh") }
                fileChoice("Transfer worker folder", current: workerPath) { selectSetupFile("worker") }
                Text("The worker folder is Tools/OracleTransfer inside your SpektraFilm source checkout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Inspect SSH Fingerprint") { hostKey.inspect(host: host) }
                    .disabled(hostKey.working)
                if hostKey.working { ProgressView().controlSize(.small) }
            }
            if !hostKey.fingerprint.isEmpty {
                Text(hostKey.fingerprint)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Toggle("I compared this SHA256 fingerprint with the VM in Oracle Console.",
                       isOn: $hostKey.independentlyVerified)
                    .font(.caption)
                Button("Trust Verified SSH Key") { hostKey.trust() }
                    .disabled(!hostKey.independentlyVerified)
            }
            Text(hostKey.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Test SSH") { runner.run(.testSSH, configuration: config) }
                Button("Install rclone on Oracle") { runner.run(.installRclone, configuration: config) }
                Button("Deploy Transfer Worker") { runner.run(.deploy, configuration: config) }
                    .buttonStyle(.borderedProminent)
            }
            Text("Install rclone downloads and runs the official rclone.org installer on the Oracle VM with non-interactive sudo. This requires Python 3, curl and sudo privileges; select it only if you trust the VM and installer.")
                .font(.caption).foregroundStyle(.secondary)
            .disabled(runner.running)
            Text("SSH strictly verifies the server's host key. Verify the VM fingerprint before accepting it; this app will not silently disable host-key checks.")
                .font(.caption).foregroundStyle(.secondary)
            jobLog
        }
    }

    private var remoteICloudStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Sign in to iCloud on Oracle", caption: "Use rclone's existing iCloud backend, not an invented Apple API. Authentication includes Apple ID, password and trusted-device 2FA.")
            Text("Option A · Guided sign-in without leaving SpektraFilm")
                .font(.headline)
            instructions([
                "Confirm the Oracle SSH connection works and rclone 1.69 or newer is installed.",
                "Start the secure setup session below. Respond to rclone's prompts: create a remote named icloud, choose iclouddrive and the drive service.",
                "When asked, enter your Apple ID and password using the fields below. Then enter the 2FA code from your trusted device.",
                "Finish the remote configuration, then select Test iCloud."
            ])
            Text("Security: your Apple credentials will be processed by rclone on your own Oracle VM. rclone's configuration obfuscates its saved password; this is not equivalent to strong encryption. Use a VM you control and protect its disk and SSH access.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(terminal.running ? "End Sign-in" : "Begin iCloud Sign-in") {
                    if terminal.running { terminal.stop() } else { terminal.start(configuration: config) }
                }
                .disabled(host.isEmpty || sshKeyPath.isEmpty)
                Button("Test iCloud Connection") { runner.run(.checkICloud, configuration: config) }
                    .disabled(runner.running)
            }
            ScrollView {
                Text(terminal.output.isEmpty ? "Rclone's setup questions will appear here after you start sign-in." : terminal.output)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 140, maxHeight: 190)
            .padding(9)
            .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
            if terminal.running {
                field("Response to rclone prompt", text: $publicResponse)
                HStack {
                    Button("Send Response") {
                        terminal.send(publicResponse, privateInput: false)
                        publicResponse = ""
                    }
                    Button("Send Enter / Accept Default") { terminal.send("", privateInput: false) }
                }
                SecureField("Private response: Apple password or 2FA", text: $secretResponse)
                    .textFieldStyle(.roundedBorder)
                Button("Send Private Response") {
                    terminal.send(secretResponse, privateInput: true)
                    secretResponse = ""
                }
                .disabled(secretResponse.isEmpty)
            }
            Divider()
            Text("Option B · Import an existing rclone configuration")
                .font(.headline)
            Text("If you already authenticated an icloud remote in rclone, choose its rclone.conf. It contains sensitive session credentials. Importing transfers it over SSH and installs it with 0600 permissions for your Oracle user.")
                .font(.caption).foregroundStyle(.secondary)
            fileChoice("rclone.conf", current: rcloneConfigPath) { selectSetupFile("rclone") }
            Toggle("I understand this copies iCloud session credentials onto my Oracle VM.", isOn: $confirmedRemoteCredentialStorage)
                .font(.caption)
            Button("Install iCloud Credentials on Oracle") {
                importer.install(localPath: rcloneConfigPath, configuration: config)
            }
            .disabled(importer.running || !confirmedRemoteCredentialStorage || rcloneConfigPath.isEmpty)
            Text(importer.status).font(.caption).foregroundStyle(importer.failed ? .red : .secondary)
            Link("iCloud rclone authentication guide", destination: URL(string: "https://rclone.org/iclouddrive/")!)
            jobLog
        }
    }

    private var lightroomStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Choose your Lightroom source", caption: "A Lightroom Cloud partner API registration alone does not give unrestricted access to RAW originals.")
            Picker("Transfer source", selection: $transferMode) {
                Text("Adobe Download All (ZIP archives)").tag("bulk")
                Text("Partner-authorized original URLs").tag("originals")
            }
            .pickerStyle(.radioGroup)
            if transferMode == "bulk" {
                Text("Use Adobe's Download All Synced Files process, then create a JSON manifest containing the authorized archive URLs. Those URLs expire and should never enter your repository.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Adobe Lightroom download", destination: URL(string: "https://lightroom.adobe.com/lightroom-library-download")!)
            } else {
                Text("Only select this mode if Adobe has approved your application for Lightroom Partner APIs and you have valid, authorized original-download URLs. Ordinary API keys do not grant entitlement.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Adobe entitlement requirements", destination: URL(string: "https://developer.adobe.com/lightroom/lightroom-api-docs/getting-started/")!)
            }
            fileChoice("Authorized JSON transfer manifest", current: manifestPath) {
                selectSetupFile("manifest")
            }
            field("Approved Adobe download hostname (optional)", text: $allowedHost)
            Text("The app transfers only the small manifest over SSH. Full RAW data flows directly from Adobe through Oracle to iCloud.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transferStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Validate, pilot, then migrate", caption: "Test one small batch before starting a multi-terabyte transfer.")
            HStack {
                Button("Validate Manifest") { runner.run(.validate, configuration: config) }
                Button("Pilot Batch") { runner.run(.pilot, configuration: config) }
                Button("Start / Resume Transfer") { runner.run(.migrate, configuration: config) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(runner.running || manifestPath.isEmpty)
            Text("Do not delete originals from Lightroom until you verify full-resolution RAW files at the destination and have an independent backup. The existing transfer scripts compare sizes but do not establish destination SHA-256 equality.")
                .font(.caption).foregroundStyle(.secondary)
            jobLog
            HStack {
                Button("Open SpektraFilm iCloud Library…") { model.openICloudLibrary() }
                Button("Sync Library") { Task { await model.synchronizeCloudNow() } }
                    .disabled(!model.isCloudLibraryConnected)
            }
        }
    }

    private var jobLog: some View {
        ScrollView {
            Text(runner.output.isEmpty ? "Connection, authentication and transfer test results appear here." : runner.output)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(8).frame(height: 105)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
    }

    private func title(_ heading: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline)
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instructions(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i+1).")
                        .font(.caption.weight(.semibold)).frame(width: 18, alignment: .trailing)
                    Text(item).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium))
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func fileChoice(_ label: String, current: String, choose: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium))
            HStack {
                Text(current.isEmpty ? "Not selected" : URL(fileURLWithPath: current).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Choose…", action: choose)
            }
        }
    }

    private func selectSetupFile(_ target: String) {
        if target == "worker" {
            SpektraFilePanel.chooseFolder(title: "Choose Oracle Transfer Worker Folder") { url in
                workerPath = url.path
            }
            return
        }
        // SSH keys and rclone.conf may not have registered macOS content types.
        SpektraFilePanel.chooseFiles(title: target == "ssh" ? "Choose SSH Key" :
                                     target == "rclone" ? "Choose rclone.conf" : "Choose Transfer Manifest") { urls in
            guard let url = urls.first else { return }
            switch target {
            case "ssh": sshKeyPath = url.path
            case "rclone": rcloneConfigPath = url.path
            default: manifestPath = url.path
            }
        }
    }
}
