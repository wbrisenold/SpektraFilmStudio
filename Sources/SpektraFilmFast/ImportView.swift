import SwiftUI

// ponytail: internal, not private — EditView and ExportView also use it.
struct LocalThumbnail: View {
    let url: URL
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?
    @State private var failed = false

    init(url: URL, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
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
