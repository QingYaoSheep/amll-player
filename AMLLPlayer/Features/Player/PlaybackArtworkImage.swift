import SwiftUI

/// Uses the existing AsyncImage path for remote images, and system-provided
/// local files for Apple Music artwork. A new URL never displays an old cover.
struct PlaybackArtworkImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var localImage: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        if let url, url.isFileURL {
            Group {
                if loadedURL == url, let localImage {
                    content(Image(uiImage: localImage))
                } else {
                    placeholder()
                }
            }
            .task(id: url) {
                do {
                    let data = try await ArtworkImageData.load(url)
                    try Task.checkCancellation()
                    guard let image = UIImage(data: data) else { return }
                    localImage = image
                    loadedURL = url
                } catch is CancellationError {}
                catch {
                    guard !Task.isCancelled else { return }
                    localImage = nil; loadedURL = nil
                }
            }
        } else {
            AsyncImage(url: url, content: content, placeholder: placeholder)
        }
    }
}
