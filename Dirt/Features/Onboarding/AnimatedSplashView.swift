import AVFoundation
import SwiftUI
import UIKit

/// Cold-launch splash: wordmark lands → one throttle pop → three quick pops →
/// wordmark surges at the camera with dirt flying off the bars → blackout into
/// the intro. Engine audio uses the owner-provided `MyKTM.m4a`.
///
/// Runs on a fixed timeline rather than waiting on bootstrap so the animation is
/// never clipped mid-blip on a fast launch; `AppGateView` holds the splash until
/// both this and bootstrap have finished.
struct AnimatedSplashView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var start = Date()
    @State private var arrived = false
    @State private var blip = 0
    @State private var surging = false
    @State private var blackout = false
    @State private var roostPaused = false
    @State private var surgePaused = true
    @State private var audio = SplashThrottleAudio()

    private let blipHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let surgeHaptic = UIImpactFeedbackGenerator(style: .heavy)

    /// One soft pop, then three quick ones. Times are seconds after `start`.
    private static let blipTimes: [Double] = [0.48, 0.92, 1.08, 1.24]
    private static let surgeAt: Double = 1.38

    var body: some View {
        ZStack {
            Color(dirtHex: 0x0B0C0E).ignoresSafeArea()

            RadialGradient(
                colors: [DirtTheme.orange.opacity(0.34), .clear],
                center: .center,
                startRadius: 4,
                endRadius: 280
            )
            .ignoresSafeArea()
            .opacity(glowOpacity)
            .blendMode(.plusLighter)

            if !reduceMotion {
                SparkBurstField(start: start, blips: Self.blipTimes, paused: roostPaused)
                    .frame(height: 280)
                    .opacity(surging ? 0 : 1)
                RoostField(start: start, blips: Self.blipTimes, paused: roostPaused)
                    .frame(height: 280)
                    .opacity(surging ? 0 : 1)

                SurgeField(start: start, surgeAt: Self.surgeAt, paused: surgePaused)
                    .ignoresSafeArea()
                    .opacity(surging ? 1 : 0)
            }

            wordmark
                .opacity(blackout ? 0 : 1)

            // Final beat — the whole frame goes black before the intro lands.
            Color.black
                .ignoresSafeArea()
                .opacity(blackout ? 1 : 0)
        }
        .task { await run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DIRT")
        .onDisappear { audio.stop() }
    }

    // MARK: - Pieces

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("DIRT")
                .italic()
                .foregroundStyle(.white)
            Text(".")
                .italic()
                .foregroundStyle(DirtTheme.orange)
                .scaleEffect(dotScale, anchor: .bottomLeading)
                .shadow(color: DirtTheme.orange.opacity(blip > 0 || surging ? 0.95 : 0), radius: surging ? 22 : 12)
        }
        .font(.system(size: 48, weight: .black))
        .opacity(arrived ? 1 : 0)
        .offset(x: offsetX)
        .scaleEffect(wordmarkScale)
        .blur(radius: surging ? (blackout ? 18 : 4) : 0)
    }

    // MARK: - Derived animation values

    private var dotScale: CGFloat {
        guard !reduceMotion else { return 1 }
        if surging { return 1.7 }
        return blip > 0 ? 1.55 : 1
    }

    private var glowOpacity: Double {
        guard !reduceMotion else { return 0.5 }
        if blackout { return 0 }
        if surging { return 1 }
        if blip > 0 { return 0.95 }
        return arrived ? 0.45 : 0
    }

    /// Lands from the left, kicks back on each blip, then holds centre for the surge.
    private var offsetX: CGFloat {
        guard !reduceMotion else { return 0 }
        if surging { return 0 }
        if !arrived { return -34 }
        return blip > 0 ? -4 : 0
    }

    private var wordmarkScale: CGFloat {
        guard !reduceMotion else { return 1 }
        if surging { return 6.2 }
        if !arrived { return 0.92 }
        return 1
    }

    // MARK: - Timeline

    private func run() async {
        start = Date()
        blipHaptic.prepare()
        surgeHaptic.prepare()

        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.3)) { arrived = true }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            onFinished()
            return
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            arrived = true
        }

        // Soft first pop.
        try? await Task.sleep(for: .milliseconds(Int(Self.blipTimes[0] * 1000)))
        guard !Task.isCancelled else { return }
        audio.play()
        await throttleBlip(intensity: 0.7)

        // Quicker pop, pop, pop.
        for time in Self.blipTimes.dropFirst() {
            let remaining = time - Date().timeIntervalSince(start)
            if remaining > 0 {
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
            guard !Task.isCancelled else { return }
            await throttleBlip(intensity: 0.9)
        }

        // Surge: wordmark fills the frame, dirt flies at the lens.
        let untilSurge = Self.surgeAt - Date().timeIntervalSince(start)
        if untilSurge > 0 {
            try? await Task.sleep(for: .milliseconds(Int(untilSurge * 1000)))
        }
        guard !Task.isCancelled else { return }
        surgePaused = false
        roostPaused = true
        surgeHaptic.impactOccurred(intensity: 1.0)
        withAnimation(.easeIn(duration: 0.48)) { surging = true }

        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.easeIn(duration: 0.22)) { blackout = true }

        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        surgePaused = true
        audio.fadeOut()
        onFinished()
    }

    private func throttleBlip(intensity: CGFloat) async {
        blipHaptic.impactOccurred(intensity: intensity)
        withAnimation(.easeOut(duration: 0.08)) { blip += 1 }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.easeIn(duration: 0.12)) { blip -= 1 }
    }
}

// MARK: - Audio

/// Plays the owner-provided motorcycle recording during the accepted splash timeline.
@MainActor
final class SplashThrottleAudio {
    private var player: AVAudioPlayer?

    func play() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        guard let url = Bundle.main.url(forResource: "MyKTM", withExtension: "m4a") else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // Ambient: respects the mute switch, mixes under Music if that's on.
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.85
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // Brand audio is optional — never block the splash on a session failure.
            player = nil
        }
    }

    func fadeOut() {
        guard let player, player.isPlaying else {
            stop()
            return
        }
        // Short fade so the blackout doesn't cut the rev mid-sample.
        player.setVolume(0, fadeDuration: 0.22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
