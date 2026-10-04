import SwiftUI

// ponytail: internal, not private — EditView and ExportView also use it.
struct LocalThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if failed {
                        Image(systemName: "photo.badge.exclamationmark")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .clipped()
        .task(id: url.path) {
            failed = false
            image = nil
            do {
                let payload = try await ThumbnailPipeline.shared.thumbnail(url: url, maxPixel: 480)
                guard !Task.isCancelled else { return }
                image = payload.makeCGImage()
                failed = image == nil
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }
}
