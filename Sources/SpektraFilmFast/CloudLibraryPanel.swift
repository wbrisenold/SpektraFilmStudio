import SwiftUI

struct CloudLibraryPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: model.isCloudLibraryConnected ? "icloud.fill" : "icloud")
                    .foregroundStyle(model.isCloudLibraryConnected ? .blue : .secondary)
                Text("ICLOUD LIBRARY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isCloudSyncing {
                    ProgressView().controlSize(.mini)
                }
            }

            Text(model.cloudLibraryStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if model.isCloudSyncing {
                ProgressView(value: model.cloudSyncProgress)
            }

            if model.isCloudLibraryConnected {
                HStack(spacing: 6) {
                    Button("Sync Now") {
                        Task { await model.synchronizeCloudNow() }
                    }
                    .disabled(model.isCloudSyncing)

                    Menu {
                        Button("Keep Selected Downloaded") {
                            model.keepSelectedCloudOriginalsDownloaded()
                        }
                        Button("Free Local Copies") {
                            model.freeSelectedCloudOriginals()
                        }
                        Divider()
                        Button("Disconnect Library") {
                            model.disconnectCloudLibrary()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .controlSize(.small)

                if let last = model.cloudLastSync {
                    Text("Last sync \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Import Lightroom → iCloud…", systemImage: "arrow.triangle.2.circlepath.icloud") {
                        model.importLightroomCatalogToICloud()
                    }
                    .help("Read a Lightroom Classic .lrcat catalog, copy its originals into iCloud Drive, preserve its develop payloads, and convert the library to SpektraFilm.")

                    Button("Move Current Library → iCloud…", systemImage: "icloud.and.arrow.up") {
                        model.moveCurrentLibraryToICloud()
                    }
                    .disabled(model.project.images.isEmpty)

                    Button("Open iCloud Library…", systemImage: "folder.badge.gearshape") {
                        model.openICloudLibrary()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(9)
        .background(StudioPalette.recessed, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.isCloudLibraryConnected ? Color.blue.opacity(0.35) : StudioPalette.subtleBorder, lineWidth: 0.5)
        }
    }
}
