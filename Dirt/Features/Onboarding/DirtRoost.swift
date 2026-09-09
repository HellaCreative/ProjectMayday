import SwiftUI

/// One thrown clod of dirt. Spawned in bursts, then purely ballistic — cheaper and
/// steadier than animating a view per particle.
private struct RoostParticle {
    let spawn: Double
    let velocity: CGVector
    let radius: CGFloat
    let life: Double
    let tint: Color
    let spin: Double
}

private struct CGVector {
    var dx: CGFloat
    var dy: CGFloat
}

/// Deterministic so the burst looks identical on every launch and in previews.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Rear-wheel roost behind the wordmark. Draw-only, so it costs one Canvas pass
/// per frame no matter how many clods are in the air.
struct RoostField: View {
    /// Wall-clock zero for the animation timeline.
    let start: Date
    /// Seconds after `start` at which a burst is thrown.
    let blips: [Double]
    /// Where the rear wheel sits, in unit coordinates of the field.
    var origin: CGPoint = CGPoint(x: 0.60, y: 0.52)
    /// Stops the redraw loop once the last clod has landed.
    var paused: Bool = false

    private static let gravity: CGFloat = 1_050

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            Canvas { ctx, size in
                let elapsed = context.date.timeIntervalSince(start)
                let anchor = CGPoint(x: size.width * origin.x, y: size.height * origin.y)

                for burst in blips.indices {
                    draw(
                        burst: burst,
                        at: blips[burst],
                        elapsed: elapsed,
                        anchor: anchor,
                        into: &ctx
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(
        burst: Int,
        at blipTime: Double,
        elapsed: Double,
        anchor: CGPoint,
        into ctx: inout GraphicsContext
    ) {
        for particle in Self.bursts[burst % Self.bursts.count] {
            let age = elapsed - blipTime - particle.spawn
            guard age > 0, age < particle.life else { continue }

            let t = CGFloat(age)
            let x = anchor.x + particle.velocity.dx * t
            let y = anchor.y + particle.velocity.dy * t + 0.5 * Self.gravity * t * t

            let decay = 1 - age / particle.life
            let radius = particle.radius * (0.45 + 0.55 * decay)
            let rect = CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2 * (1 + particle.spin * Double(decay))
            )

            ctx.fill(
                Path(ellipseIn: rect),
                with: .color(particle.tint.opacity(decay * decay))
            )
        }
    }

    // MARK: - Burst generation

    private static let bursts: [[RoostParticle]] = [
        makeBurst(seed: 0x5EED_1234, count: 26),
        makeBurst(seed: 0xBEEF_4321, count: 30)
    ]

    private static func makeBurst(seed: UInt64, count: Int) -> [RoostParticle] {
        var rng = SeededRNG(seed: seed)
        let tints = [
            Color(dirtHex: 0x7A4E22),
            Color(dirtHex: 0xA9743A),
            Color(dirtHex: 0xD9C3A5),
            DirtTheme.orange
        ]

        return (0..<count).map { index in
            // Spray back and up from the contact patch, with a few low skips.
            let degrees = Double.random(in: 155...232, using: &rng)
            let radians = degrees * .pi / 180
            let speed = Double.random(in: 150...470, using: &rng)
            // A couple of bright sparks carry further than the clods.
            let isSpark = index % 9 == 0

            return RoostParticle(
                spawn: Double.random(in: 0...0.06, using: &rng),
                velocity: CGVector(
                    dx: CGFloat(cos(radians) * speed),
                    dy: CGFloat(sin(radians) * speed) - CGFloat(isSpark ? 120 : 0)
                ),
                radius: CGFloat.random(in: isSpark ? 1.2...2.0 : 1.8...4.6, using: &rng),
                life: Double.random(in: isSpark ? 0.75...1.05 : 0.45...0.85, using: &rng),
                tint: isSpark ? DirtTheme.orange : tints[Int.random(in: 0..<3, using: &rng)],
                spin: Double.random(in: 0...0.5, using: &rng)
            )
        }
    }
}

// MARK: - Camera surge

/// One clod flung *at* the rider — grows as it approaches, instead of arcing sideways.
private struct SurgeParticle {
    let spawn: Double
    /// Direction on the screen plane (unit-ish).
    let direction: CGVector
    /// How fast it expands toward the camera (radius growth / second).
    let approach: CGFloat
    let startRadius: CGFloat
    let life: Double
    let tint: Color
}

/// Dirt flying out of the wordmark toward the screen during the splash takeoff.
struct SurgeField: View {
    let start: Date
    /// Seconds after `start` when the surge begins.
    var surgeAt: Double = 0
    var paused: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            Canvas { ctx, size in
                let elapsed = context.date.timeIntervalSince(start) - surgeAt
                guard elapsed > 0 else { return }
                let anchor = CGPoint(x: size.width * 0.52, y: size.height * 0.48)

                for particle in Self.particles {
                    let age = elapsed - particle.spawn
                    guard age > 0, age < particle.life else { continue }

                    let t = CGFloat(age)
                    let travel = t * particle.approach * 56
                    let x = anchor.x + particle.direction.dx * travel
                    let y = anchor.y + particle.direction.dy * travel
                    // Grow hard as it "nears" the lens.
                    let radius = particle.startRadius + particle.approach * t * t * 34
                    let decay = 1 - age / particle.life
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )

                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(particle.tint.opacity(decay * decay * 0.95))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static let particles: [SurgeParticle] = makeSurge(seed: 0xD187_50A7, count: 72)

    private static func makeSurge(seed: UInt64, count: Int) -> [SurgeParticle] {
        var rng = SeededRNG(seed: seed)
        let tints = [
            Color(dirtHex: 0x5C3A18),
            Color(dirtHex: 0x7A4E22),
            Color(dirtHex: 0xA9743A),
            Color(dirtHex: 0xD9C3A5),
            DirtTheme.orange
        ]

        return (0..<count).map { index in
            let degrees = Double.random(in: 0..<360, using: &rng)
            let radians = degrees * .pi / 180
            // Bias a little toward the lower half — roost coming over the bars.
            let biasY = Double.random(in: 0.2...1.15, using: &rng)
            let isSpark = index % 6 == 0

            return SurgeParticle(
                spawn: Double.random(in: 0...0.14, using: &rng),
                direction: CGVector(
                    dx: CGFloat(cos(radians)),
                    dy: CGFloat(sin(radians) * biasY)
                ),
                approach: CGFloat.random(in: isSpark ? 12...18 : 8...14, using: &rng),
                startRadius: CGFloat.random(in: isSpark ? 1.2...2.8 : 2.5...7.0, using: &rng),
                life: Double.random(in: isSpark ? 0.45...0.75 : 0.55...1.0, using: &rng),
                tint: isSpark ? DirtTheme.orange : tints[Int.random(in: 0..<tints.count - 1, using: &rng)]
            )
        }
    }
}

/// Brief hot sparks on the throttle beats; one canvas, no per-particle views.
struct SparkBurstField: View {
    let start: Date
    let blips: [Double]
    var paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let origin = CGPoint(x: size.width * 0.6, y: size.height * 0.52)
                for beat in blips {
                    let age = elapsed - beat
                    guard age >= 0, age < 0.34 else { continue }
                    for index in 0..<18 {
                        let angle = Double(index) * 2.39996
                        let speed = Double(180 + (index * 37) % 220)
                        let distance = age * speed
                        let tail = max(0, distance - 8 - age * 20)
                        var path = Path()
                        path.move(to: CGPoint(x: origin.x + cos(angle) * tail, y: origin.y + sin(angle) * tail))
                        path.addLine(to: CGPoint(x: origin.x + cos(angle) * distance, y: origin.y + sin(angle) * distance))
                        context.stroke(path, with: .color((index % 3 == 0 ? Color.white : DirtTheme.orange).opacity(1 - age / 0.34)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
