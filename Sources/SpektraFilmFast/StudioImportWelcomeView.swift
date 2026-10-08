import SwiftUI

/// Always exposes project actions, including when no recent documents exist.
/// This is a project launcher first and an image importer second.
struct StudioImportWelcomeView: View {
    @ObservedObject var model: AppModel
    @Binding var showingWizard: Bool
    @Binding var preferredSource: String?
    @State private var recentProjects: [URL] = RecentSpektraProjects.urls

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, height: 70)
                        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 17))
                        .accessibilityHidden(true)

                    VStack(spacing: 7) {
                        Text("Your projects")
                            .font(.system(size: 27, weight: .semibold))
                        Text("Start a project, reopen your work, or import photos into SpektraFilm.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !model.project.images.isEmpty {
                        Button {
                            model.showProjectHome = false
                        } label: {
                            Label("Return to current library", systemImage: "arrow.left")
                        }
                        .buttonStyle(.link)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("PROJECTS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { model.newProject() } label: {
                                Label("New Project", systemImage: "plus.rectangle.on.rectangle")
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { model.openProject() } label: {
                                Label("Open Project…", systemImage: "folder")
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)

                        Text("RECENT PROJECTS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)

                        if recentProjects.isEmpty {
                            HStack(spacing: 9) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("No recent projects yet. Saved and opened projects appear here automatically.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 9))
                        } else {
                            ForEach(recentProjects, id: \.path) { url in
                                Button {
                                    if FileManager.default.fileExists(atPath: url.path) {
                                        model.openProject(at: url)
                                    } else {
                                        // Keep a visible history entry even when its drive is offline.
                                        model.status = "Recent project missing; choose its new location"
                                        model.openProject()
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: FileManager.default.fileExists(atPath: url.path)
                                              ? "doc.text" : "externaldrive.badge.exclamationmark")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(url.deletingPathExtension().lastPathComponent)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            Text(FileManager.default.fileExists(atPath: url.path)
                                                 ? url.deletingLastPathComponent().path
                                                 : "Unavailable · select its new location")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxWidth: 600)

                    VStack(alignment: .leading, spacing: 11) {
                        Text("IMPORT & CLOUD")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                preferredSource = "Folder or card"
                                showingWizard = true
                            } label: {
                                Label("Import Photos…", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button { model.openICloudLibrary() } label: {
                                Label("Open iCloud Library…", systemImage: "icloud")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        HStack(spacing: 10) {
                            quickOption("Shoot or card", icon: "externaldrive", source: "Folder or card")
                            quickOption("Lightroom Classic", icon: "square.stack.3d.up", source: "Lightroom Classic")
                        }
                        if !model.cloudLibraryStatus.isEmpty && model.cloudLibraryStatus != "Not connected" {
                            Text(model.cloudLibraryStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 600)

                    if model.hasRecoverableIngest {
                        Button("Resume previous verified import") { model.resumeManagedIngest() }
                            .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(StudioPalette.canvas)
        .onAppear { recentProjects = RecentSpektraProjects.urls }
        .onReceive(NotificationCenter.default.publisher(for: RecentSpektraProjects.changed)) { _ in
            recentProjects = RecentSpektraProjects.urls
        }
    }

    private func quickOption(_ title: String, icon: String, source: String) -> some View {
        Button {
            preferredSource = source
            showingWizard = true
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.bordered)
    }
}
