import AVFoundation
import SwiftUI
import UIKit

/// Full-bleed looping background for the first intro slide. Muted — the splash
/// owns the engine recording. Fill-crop so a landscape ride still covers portrait.
struct RideBackdropVideo: View {
    var playing: Bool

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            Color(dirtHex: 0x0B0C0E)
            if let player {
                RidePlayerLayer(player: player)
                    .opacity(0.70)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
        .onAppear { boot() }
        .onChange(of: playing) { _, on in
            on ? player?.play() : player?.pause()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func boot() {
        guard player == nil else {
            if playing { player?.play() }
            return
        }
        guard let url = Bundle.main.url(forResource: "ride", withExtension: "mov") else {
            return
        }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        if playing { queue.play() }
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
}
