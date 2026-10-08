import SwiftUI

/// The first-run Library state has one primary next action, not an empty gallery
/// surrounded by folders, people, filters and other advanced administration UI.
struct StudioImportWelcomeView: View {
    @ObservedObject var model: AppModel
    @Binding var showingWizard: Bool
    @Binding var preferredSource: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 37, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                        .frame(width: 82, height: 82)
                        .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Your photos start here")
                            .font(.system(size: 29, weight: .semibold, design: .default))
                        Text("Import a shoot, bring over your Lightroom Classic catalog, or open your iCloud library. SpektraFilm preserves your original files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 510)
                    }

                    Button {
                        showingWizard = true
                    } label: {
                        Label("Import Photos…", systemImage: "plus")
                            .frame(minWidth: 176)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("i", modifiers: [.command])

                    HStack(alignment: .top, spacing: 10) {
                        quickOption("Shoot or card", icon: "externaldrive", detail: "RAW files, JPEGs and folders", source: "Folder or card")
                        quickOption("Lightroom Classic", icon: "square.stack.3d.up", detail: "Catalog, collections and edits", source: "Lightroom Classic")
                        quickOption("iCloud Library", icon: "icloud", detail: "Continue editing on this Mac", source: "Existing iCloud library")
                    }
                    .frame(maxWidth: 720)

                    if !RecentSpektraProjects.urls.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("RECENT PROJECTS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(RecentSpektraProjects.urls, id: \.path) { url in
                                Button {
                                    model.openProject(at: url)
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(url.deletingLastPathComponent().lastPathComponent)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(9)
                                }
                                .buttonStyle(.plain)
                                .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        .frame(maxWidth: 640)
                    }

                    if model.hasRecoverableIngest {
                        Button("Resume previous verified import") {
                            model.resumeManagedIngest()
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 45)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(StudioPalette.canvas)
    }

    private func quickOption(_ title: String, icon: String, detail: String, source: String) -> some View {
        Button {
            preferredSource = source
            showingWizard = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 116)
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(StudioPalette.subtleBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
