import AppKit
import SwiftUI

/// Square (or freeform) loading stand-in with a quick bottom-leading → top-trailing wipe.
struct ShimmerBlockPlaceholder: View {
    /// When true, locks to a 1:1 block aspect (grid cells). When false, fills the offered frame (media pane).
    var square: Bool = true
    var showsBorder: Bool = true

    var body: some View {
        Group {
            if square {
                shimmer
                    .aspectRatio(1, contentMode: .fit)
            } else {
                shimmer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .overlay {
            if showsBorder {
                Rectangle().stroke(ColosseumTheme.border, lineWidth: 1)
            }
        }
        .accessibilityLabel("Loading")
    }

    private var shimmer: some View {
        // Quick wipe — under half a second per pass, BL → TR.
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { context in
            let cycle = 0.42
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle
            let x = t * 1.55 - 0.28
            ZStack {
                ColosseumTheme.surface
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: clamp(x - 0.14)),
                        .init(color: ColosseumTheme.shimmerHighlight, location: clamp(x)),
                        .init(color: .clear, location: clamp(x + 0.14))
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            }
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

/// Loads a remote image over a shimmer placeholder, then crossfades the media in.
struct ShimmerRemoteImage<Failure: View>: View {
    let url: URL
    var square: Bool = true
    var showsBorder: Bool = true
    var contentPadding: CGFloat = 0
    /// When true, loads full-resolution pixels (previews). Grid cells keep the default thumb path.
    var fullResolution: Bool = false
    var failure: () -> Failure

    @State private var image: Image?
    @State private var didFail = false
    @State private var loadID = 0

    private var showMedia: Bool { image != nil }
    private var showFailure: Bool { didFail && image == nil }

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(contentPadding)
                    .transition(ColosseumMotion.mediaReveal)
            } else if showFailure {
                failure()
                    .padding(contentPadding)
                    .transition(.opacity)
            } else {
                ShimmerBlockPlaceholder(square: square, showsBorder: showsBorder)
                    .padding(contentPadding)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: square ? nil : .infinity)
        .animation(ColosseumMotion.standard, value: showMedia)
        .animation(ColosseumMotion.soft, value: showFailure)
        .task(id: "\(url.absoluteString)#\(fullResolution)") {
            await load()
        }
    }

    @MainActor
    private func load() async {
        loadID += 1
        let ticket = loadID
        didFail = false

        if fullResolution {
            if let cached = ImageThumbCache.cachedFullImage(for: url) {
                image = Image(nsImage: cached)
                return
            }
            // Show a grid thumb immediately while the full asset loads.
            if let thumb = ImageThumbCache.cachedImage(for: url) {
                image = Image(nsImage: thumb)
            } else {
                image = nil
            }

            let loaded = await ImageThumbCache.fullImage(for: url)
            guard ticket == loadID, !Task.isCancelled else { return }
            if let loaded {
                image = Image(nsImage: loaded)
            } else if image == nil {
                didFail = true
            }
            return
        }

        if let cached = ImageThumbCache.cachedImage(for: url) {
            image = Image(nsImage: cached)
            return
        }

        // Only clear once we know this is a cold load (keeps scroll-back cache hits instant).
        image = nil

        let loaded = await ImageThumbCache.image(for: url)
        guard ticket == loadID, !Task.isCancelled else { return }
        if let loaded {
            image = Image(nsImage: loaded)
        } else {
            didFail = true
        }
    }
}
