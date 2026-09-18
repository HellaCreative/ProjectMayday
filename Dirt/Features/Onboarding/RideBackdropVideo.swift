import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Full-bleed ride plate for the first intro slide. Muted — splash owns the engine
/// recording. Plays once, stays at 70% opacity, then fades to the dark ground
/// just before the clip ends. Does not loop.
struct RideBackdropVideo: View {
    var playing: Bool

    @StateObject private var playback = RideBackdropPlayback()

    var body: some View {
        ZStack {
            Color(dirtHex: 0x0B0C0E)
            RidePlayerLayer(player: playback.player)
                .opacity(playback.plateOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .onAppear { playback.setPlaying(playing) }
        .onChange(of: playing) { _, on in
            playback.setPlaying(on)
        }
        .onDisappear { playback.setPlaying(false) }
    }
}

@MainActor
final class RideBackdropPlayback: ObservableObject {
    /// Visible plate strength until the pre-end fade. 0.70 = 70% video, 30% dark.
    static let plateStrength: Double = 0.70
    /// Begin the fade this far before the last frame so it does not hang on the end.
    private static let fadeLead: TimeInterval = 0.90
    private static let fadeLength: TimeInterval = 0.75

    @Published var plateOpacity: Double = plateStrength

    let player = AVPlayer()

    private var item: AVPlayerItem?
    private var statusObs: NSKeyValueObservation?
    private var fadeObserver: Any?
    private var tickObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var wantsPlay = false
    private var fadeStarted = false
    private var loadedDuration: TimeInterval?
    private var kickRetry: DispatchWorkItem?

    func setPlaying(_ on: Bool) {
        wantsPlay = on
        if on {
            start()
        } else {
            pause()
        }
    }

    private func start() {
        if item == nil {
            boot()
        } else {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.wantsPlay else { return }
                    self.fadeStarted = false
                    self.plateOpacity = Self.plateStrength
                    self.armFade()
                    self.kickPlay()
                }
            }
        }
        kickPlay()
    }

    private func pause() {
        kickRetry?.cancel()
        player.pause()
    }

    private func boot() {
        guard let url = Self.resourceURL else { return }

        let item = AVPlayerItem(url: url)
        self.item = item
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false

        statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.captureDuration()
                    self.armFade()
                    if self.wantsPlay { self.kickPlay() }
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self, let item = self.item else { return }
            if let duration = try? await item.asset.load(.duration) {
                let seconds = duration.seconds
                if seconds.isFinite, seconds > 0 {
                    self.loadedDuration = seconds
                    self.armFade()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finishOnBlack()
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsPlay, !self.fadeStarted else { return }
                self.kickPlay()
            }
        }

        kickPlay()
    }

    private func kickPlay() {
        guard wantsPlay, !fadeStarted else { return }
        activateSession()
        if player.timeControlStatus != .playing {
            player.playImmediately(atRate: 1)
        }
        // Splash deactivates its session as the intro lands; one kick after
        // that teardown so a muted AVPlayer is not left on the first frame.
        kickRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.wantsPlay, !self.fadeStarted else { return }
                if self.player.timeControlStatus != .playing {
                    self.activateSession()
                    self.player.playImmediately(atRate: 1)
                }
            }
        }
        kickRetry = work
        // Splash stop() deactivates the session ~0.25s after intro appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
    }

    private func captureDuration() {
        if let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 {
            loadedDuration = seconds
        } else if let seconds = item?.asset.duration.seconds, seconds.isFinite, seconds > 0 {
            loadedDuration = seconds
        }
    }

    private var resolvedDuration: TimeInterval? {
        if let loadedDuration, loadedDuration.isFinite, loadedDuration > 0 {
            return loadedDuration
        }
        if let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 {
            return seconds
        }
        if let seconds = item?.asset.duration.seconds, seconds.isFinite, seconds > 0 {
            return seconds
        }
        return nil
    }

    private func armFade() {
        if let fadeObserver {
            player.removeTimeObserver(fadeObserver)
            self.fadeObserver = nil
        }
        if let tickObserver {
            player.removeTimeObserver(tickObserver)
            self.tickObserver = nil
        }
        guard let duration = resolvedDuration, duration > Self.fadeLead + 0.2 else { return }
        let fireAt = CMTime(seconds: duration - Self.fadeLead, preferredTimescale: 600)
        fadeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: fireAt)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor in
                self?.beginFade()
            }
        }
        // Backup if the player jumps past the boundary (stall, late duration).
        tickObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.fadeStarted, let duration = self.resolvedDuration else { return }
                let now = time.seconds
                guard now.isFinite, now >= duration - Self.fadeLead else { return }
                self.beginFade()
            }
        }
    }

    private func beginFade() {
        guard !fadeStarted else { return }
        fadeStarted = true
        withAnimation(DirtMotion.reduceMotion ? .easeIn(duration: 0.2) : .easeIn(duration: Self.fadeLength)) {
            plateOpacity = 0
        }
    }

    private func finishOnBlack() {
        kickRetry?.cancel()
        player.pause()
        fadeStarted = true
        withAnimation(.easeIn(duration: 0.12)) {
            plateOpacity = 0
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    private static var resourceURL: URL? {
        Bundle.main.url(forResource: "ride", withExtension: "mov")
            ?? Bundle.main.url(forResource: "ride", withExtension: "mov", subdirectory: "Resources")
    }

    deinit {
        kickRetry?.cancel()
        if let fadeObserver {
            player.removeTimeObserver(fadeObserver)
        }
        if let tickObserver {
            player.removeTimeObserver(tickObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
    }
}

private struct RidePlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> RidePlayerView {
        let view = RidePlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: RidePlayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
    }
}

private final class RidePlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
