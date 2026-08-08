import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Plays multi-frame images (GIF) via AppKit — SwiftUI `Image` only shows frame 0.
///
/// Always adopts the size SwiftUI proposes. A bare `NSImageView` otherwise reports
/// the GIF's full pixel size and blows up LazyVGrid cells.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    var imageScaling: NSImageScaling = .scaleProportionallyUpOrDown
    var onLoad: () -> Void = {}

    private static let remoteCache = NSCache<NSURL, NSImage>()

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = ClippingContainerView()
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = imageScaling
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.imageView = imageView
        context.coordinator.onLoad = onLoad
        context.coordinator.load(url: url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.imageView?.imageScaling = imageScaling
        context.coordinator.onLoad = onLoad
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url)
        } else {
            // Re-assert after SwiftUI updates; animates must be true after image is set.
            context.coordinator.imageView?.animates = true
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width
        let height = proposal.height
        switch (width, height) {
        case let (w?, h?) where w.isFinite && h.isFinite && w > 0 && h > 0:
            return CGSize(width: w, height: h)
        case let (w?, nil) where w.isFinite && w > 0:
            return CGSize(width: w, height: w)
        case let (nil, h?) where h.isFinite && h > 0:
            return CGSize(width: h, height: h)
        default:
            return .zero
        }
    }

    final class Coordinator {
        var currentURL: URL?
        weak var imageView: NSImageView?
        var onLoad: () -> Void = {}
        private var dataTask: URLSessionDataTask?
        private var didNotifyLoad = false

        func load(url: URL) {
            dataTask?.cancel()
            dataTask = nil
            didNotifyLoad = false
            currentURL = url
            guard let imageView else { return }
            if url.isFileURL {
                imageView.image = NSImage(contentsOf: url)
                imageView.animates = true
                notifyLoaded()
                return
            }
            if let cached = AnimatedImageView.remoteCache.object(forKey: url as NSURL) {
                imageView.image = cached
                imageView.animates = true
                notifyLoaded()
                return
            }

            imageView.image = nil
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                guard let data else { return }
                DispatchQueue.main.async {
                    guard let self, self.currentURL == url, let image = NSImage(data: data) else { return }
                    AnimatedImageView.remoteCache.setObject(image, forKey: url as NSURL)
                    self.imageView?.image = image
                    self.imageView?.animates = true
                    self.notifyLoaded()
                }
            }
            dataTask?.resume()
        }

        deinit {
            dataTask?.cancel()
        }

        private func notifyLoaded() {
            guard !didNotifyLoad else { return }
            didNotifyLoad = true
            DispatchQueue.main.async { [weak self] in self?.onLoad() }
        }
    }
}

/// Keeps a static remote frame visible until the animated image has decoded.
struct RemoteAnimatedImageView: View {
    let url: URL
    var placeholderURL: URL?
    var square = false
    var contentPadding: CGFloat = 0

    @State private var isReady = false

    var body: some View {
        ZStack {
            ShimmerRemoteImage(
                url: placeholderURL ?? url,
                square: square,
                showsBorder: false,
                contentPadding: contentPadding
            ) {
                Color.clear
            }

            AnimatedImageView(url: url) {
                isReady = true
            }
            .padding(contentPadding)
            .opacity(isReady ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: square ? nil : .infinity)
        .animation(ColosseumMotion.standard, value: isReady)
        .onChange(of: url) { _, _ in isReady = false }
    }
}

/// Clips AppKit drawing and never contributes an intrinsic size to SwiftUI.
private final class ClippingContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var isFlipped: Bool { true }
}

/// Wraps `AVPlayerView` instead of SwiftUI `VideoPlayer`, which can abort when
/// AVKit isn't fully linked in SPM/distributed macOS builds.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls: Bool = true
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = videoGravity
        view.player = player
        // Avoid the default grey letterbox flash before the first frame.
        view.wantsLayer = true
        view.layer?.backgroundColor = ColosseumTheme.nsCanvas.cgColor
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.controlsStyle = showsControls ? .inline : .none
        nsView.videoGravity = videoGravity
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// Owns an `AVQueuePlayer` + `AVPlayerLooper` so clips repeat cleanly.
final class LoopingVideoPlayer {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var didReportReady = false
    /// Fired on the main queue once the playing item can present frames.
    var onReady: (() -> Void)?

    init(url: URL, muted: Bool) {
        let queue = AVQueuePlayer()
        queue.isMuted = muted
        let item = AVPlayerItem(url: url)
        player = queue
        // Observe the item actually enqueued by the looper (not only the template).
        currentItemObservation = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] queue, _ in
            self?.watchStatus(of: queue.currentItem)
        }
        looper = AVPlayerLooper(player: queue, templateItem: item)
    }

    func play() {
        player.play()
    }

    func stop() {
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        onReady = nil
        didReportReady = false
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }

    private func watchStatus(of item: AVPlayerItem?) {
        statusObservation?.invalidate()
        statusObservation = nil
        guard let item else { return }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self, item.status == .readyToPlay, !self.didReportReady else { return }
            self.didReportReady = true
            DispatchQueue.main.async {
                self.onReady?()
            }
        }
    }

    deinit {
        currentItemObservation?.invalidate()
        statusObservation?.invalidate()
        player.pause()
        looper?.disableLooping()
    }
}

/// Per-cell video session so ready-state updates reliably (escaping `@State` sets do not).
@MainActor
final class CellVideoSession: ObservableObject {
    @Published private(set) var isReady = false
    private(set) var looping: LoopingVideoPlayer?

    var player: AVPlayer? { looping?.player }

    func start(url: URL, muted: Bool = true) {
        if let looping {
            looping.play()
            return
        }
        isReady = false
        let next = VideoPlayback.looping(url: url, muted: muted)
        next.onReady = { [weak self] in
            Task { @MainActor in
                self?.isReady = true
            }
        }
        looping = next
        next.play()
    }

    func stop() {
        looping?.stop()
        looping = nil
        isReady = false
    }
}

enum VideoPlayback {
    static func looping(url: URL, muted: Bool) -> LoopingVideoPlayer {
        LoopingVideoPlayer(url: url, muted: muted)
    }
}
