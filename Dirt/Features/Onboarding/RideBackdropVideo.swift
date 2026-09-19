import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Full-bleed ride plate for the first intro slide. Muted — splash owns the engine
/// recording. Plays once through the file, stays at 70% opacity, then fades to the
/// dark ground just before the last frame. Does not loop.
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
        // Do not pause in onDisappear. SwiftUI can emit that during the splash
        // → intro transition and TabView layout without leaving page 0, which
        // froze the plate around one second in.
    }
}

@MainActor
final class RideBackdropPlayback: ObservableObject {
    /// Visible plate strength until the pre-end fade. 0.70 = 70% video, 30% dark.
    static let plateStrength: Double = 0.70
    /// Begin the fade this far before the last frame so it does not hang on the end.
    private static let fadeLead: TimeInterval = 0.90
    private static let fadeLength: TimeInterval = 0.75
    /// ride.mov is ~17.7s. Reject placeholder durations so a 1s stall cannot fade.
    private static let minimumRealDuration: TimeInterval = 5

    @Published var plateOpacity: Double = plateStrength

    let player = AVPlayer()

    private var item: AVPlayerItem?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var tickObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var wantsPlay = false
    private var fadeStarted = false
    private var loadedDuration: TimeInterval?
    private var keepAlive: DispatchWorkItem?

    func setPlaying(_ on: Bool) {
        let wasOn = wantsPlay
        wantsPlay = on
        if on {
            start(restart: wasOn == false && item != nil)
        } else {
            pause()
        }
    }

    private func start(restart: Bool) {
        if item == nil {
            boot()
            return
        }
        if restart {
            fadeStarted = false
            plateOpacity = Self.plateStrength
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsPlay else { return }
                    self.kickPlay()
                }
            }
        }
        kickPlay()
    }

    private func pause() {
        keepAlive?.cancel()
        player.pause()
    }

    private func boot() {
        guard let url = Self.resourceURL else { return }

        let item = AVPlayerItem(url: url)
        self.item = item
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        // Waiting is required. playImmediately + no-wait stalled after the
        // first ~1s GOP and never reached the pre-end fade.
        player.automaticallyWaitsToMinimizeStalling = true

        statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.item?.status == .readyToPlay {
                    self.captureDuration()
                    if self.wantsPlay { self.kickPlay() }
                }
            }
        }

        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.wantsPlay, !self.fadeStarted else { return }
                if self.player.timeControlStatus == .paused {
                    self.kickPlay()
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self, let item = self.item else { return }
            if let duration = try? await item.asset.load(.duration) {
                let seconds = duration.seconds
                if seconds.isFinite, seconds >= Self.minimumRealDuration {
                    self.loadedDuration = seconds
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEnded()
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wantsPlay, !self.fadeStarted else { return }
                self.kickPlay()
            }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(type)
            }
        }

        armTick()
        kickPlay()
        scheduleKeepAlive()
    }

    private func kickPlay() {
        guard wantsPlay, !fadeStarted else { return }
        activateSession()
        if player.timeControlStatus != .playing {
            player.play()
        }
    }

    /// Splash used to deactivate the session ~0.25–1s after intro lands, which
    /// pauses AVPlayer even when muted. Keep nudging play until it sticks.
    private func scheduleKeepAlive() {
        keepAlive?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.wantsPlay, !self.fadeStarted else { return }
                self.kickPlay()
                if self.player.timeControlStatus != .playing {
                    self.scheduleKeepAlive()
                }
            }
        }
        keepAlive = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func captureDuration() {
        // Asset duration is loaded asynchronously in boot(); the ready item's
        // duration is also safe to read without the deprecated synchronous asset API.
        if let seconds = item?.duration.seconds, seconds.isFinite, seconds >= Self.minimumRealDuration {
            loadedDuration = seconds
        }
    }

    private var resolvedDuration: TimeInterval? {
        if let loadedDuration, loadedDuration.isFinite, loadedDuration >= Self.minimumRealDuration {
            return loadedDuration
        }
        if let seconds = item?.duration.seconds, seconds.isFinite, seconds >= Self.minimumRealDuration {
            return seconds
        }
        return nil
    }

    private func armTick() {
        if let tickObserver {
            player.removeTimeObserver(tickObserver)
            self.tickObserver = nil
        }
        tickObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.tick(time)
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard wantsPlay else { return }
        if !fadeStarted, player.timeControlStatus != .playing {
            kickPlay()
        }
        guard !fadeStarted else { return }
        let now = time.seconds
        guard now.isFinite, now > 1 else { return }
        guard let duration = resolvedDuration else { return }
        if now >= duration - Self.fadeLead {
            beginFade()
        }
    }

    private func beginFade() {
        guard !fadeStarted else { return }
        guard let duration = resolvedDuration, duration >= Self.minimumRealDuration else { return }
        let now = player.currentTime().seconds
        guard now.isFinite, now >= duration - Self.fadeLead else { return }
        fadeStarted = true
        keepAlive?.cancel()
        withAnimation(DirtMotion.reduceMotion ? .easeIn(duration: 0.2) : .easeIn(duration: Self.fadeLength)) {
            plateOpacity = 0
        }
    }

    private func handleEnded() {
        let now = player.currentTime().seconds
        if let duration = resolvedDuration, now.isFinite, now < duration - 0.35 {
            // False end (short placeholder duration / stall). Keep playing.
            fadeStarted = false
            kickPlay()
            return
        }
        finishOnBlack()
    }

    private func finishOnBlack() {
        fadeStarted = true
        keepAlive?.cancel()
        player.pause()
        withAnimation(.easeIn(duration: 0.12)) {
            plateOpacity = 0
        }
    }

    private func handleInterruption(_ type: UInt?) {
        guard wantsPlay, !fadeStarted else { return }
        if type == AVAudioSession.InterruptionType.ended.rawValue {
            kickPlay()
            scheduleKeepAlive()
        }
        // Began: splash setActive(false) used to arrive here. Do not pause
        // ourselves — kickPlay resumes once the session is usable again.
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
        keepAlive?.cancel()
        if let tickObserver {
            player.removeTimeObserver(tickObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
}

private struct RidePlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> RidePlayerView {
        let view = RidePlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.needsDisplayOnBoundsChange = true
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
