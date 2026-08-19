import SwiftUI

/// Short celebratory burst when a route finishes building (From here / Plan / Loop).
/// Pure SwiftUI — no third-party particles. Brief, brand-tinted, non-interactive.
struct RouteSuccessConfetti: View {
    private struct Piece: Identifiable {
        let id = UUID()
        let color: Color
        let size: CGSize
        let start: CGPoint
        let end: CGPoint
        let spin: Double
        let delay: Double
    }

    @State private var pieces: [Piece] = []
    @State private var exploded = false

    private let palette: [Color] = [
        DirtTheme.orange,
        DirtTheme.navGreen,
        Color(dirtHex: 0xF5C542),
        Color(dirtHex: 0x2E8BFF),
        Color(dirtHex: 0xE85D4C),
        .white
    ]

    var body: some View {
        GeometryReader { geo in
            let origin = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.22)
            ZStack {
                ForEach(pieces) { piece in
                    Capsule()
                        .fill(piece.color)
                        .frame(width: piece.size.width, height: piece.size.height)
                        .rotationEffect(.degrees(exploded ? piece.spin : 0))
                        .position(exploded ? piece.end : origin)
                        .opacity(exploded ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.35).delay(piece.delay),
                            value: exploded
                        )
                }
            }
            .onAppear {
                pieces = Self.makePieces(origin: origin, in: geo.size, colors: palette)
                exploded = false
                DispatchQueue.main.async {
                    exploded = true
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func makePieces(origin: CGPoint, in size: CGSize, colors: [Color]) -> [Piece] {
        (0..<48).map { i in
            let angle = Double.random(in: -0.95 * .pi ... -0.05 * .pi) // upward fan
            let distance = Double.random(in: 120...min(size.height * 0.55, 340))
            let dx = cos(angle) * distance
            let dy = sin(angle) * distance + Double.random(in: 40...160) // then fall
            return Piece(
                color: colors[i % colors.count],
                size: CGSize(
                    width: CGFloat.random(in: 4...7),
                    height: CGFloat.random(in: 8...14)
                ),
                start: origin,
                end: CGPoint(x: origin.x + dx, y: origin.y - dy + distance * 0.9),
                spin: Double.random(in: -540...540),
                delay: Double.random(in: 0...0.12)
            )
        }
    }
}
