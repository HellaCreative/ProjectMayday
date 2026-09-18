import SwiftUI

// MARK: - Shared canvas

/// Flexible stage so later slides can give the picture most of the height
/// and keep it away from the title.
private struct IllustrationStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - 1. Logo build

/// Brand beat on the first intro slide: wordmark almost full width, roost and
/// throttle pops over the ride plate.
struct LogoBuildArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var start = Date()
    @State private var settled = false
    @State private var blip = 0
    @State private var paused = true
    @State private var kick: CGFloat = 1

    private static let blipTimes: [Double] = [0.28, 0.62, 0.88, 1.12]

    var body: some View {
        GeometryReader { geo in
            let mark = min(geo.size.width * 0.34, 128)
            ZStack {
                if !reduceMotion {
                    SparkBurstField(
                        start: start,
                        blips: Self.blipTimes,
                        paused: paused
                    )
                    RoostField(
                        start: start,
                        blips: Self.blipTimes,
                        origin: CGPoint(x: 0.58, y: 0.62),
                        paused: paused
                    )
                }

                HStack(spacing: 0) {
                    Text("DIRT")
                        .italic()
                        .foregroundStyle(.white)
                    Text(".")
                        .italic()
                        .foregroundStyle(DirtTheme.orange)
                        .scaleEffect(blip > 0 ? 1.7 : 1, anchor: .bottomLeading)
                        .shadow(
                            color: DirtTheme.orange.opacity(blip > 0 || settled ? 0.95 : 0),
                            radius: blip > 0 ? 28 : 14
                        )
                }
                .font(.system(size: mark, weight: .black))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .opacity(settled ? 1 : 0)
                .offset(x: settled ? (blip > 0 ? -8 : 0) : -geo.size.width * 0.12)
                .scaleEffect(kick)
                .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .accessibilityHidden(true)
        }
        .onChange(of: isActive, initial: true) { _, active in
            guard active else {
                paused = true
                return
            }
            Task { await play() }
        }
    }

    private func play() async {
        guard !reduceMotion else {
            settled = true
            kick = 1
            return
        }

        start = Date()
        paused = false
        settled = false
        kick = 0.72
        withAnimation(.spring(response: 0.46, dampingFraction: 0.58)) {
            settled = true
            kick = 1.08
        }
        try? await Task.sleep(for: .milliseconds(280))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { kick = 1 }

        for (index, time) in Self.blipTimes.enumerated() {
            let previous = index == 0 ? 0 : Self.blipTimes[index - 1]
            try? await Task.sleep(for: .milliseconds(Int((time - previous) * 1000)))
            withAnimation(.easeOut(duration: 0.08)) {
                blip += 1
                kick = 1.06
            }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeIn(duration: 0.14)) {
                blip -= 1
                kick = 1
            }
        }

        try? await Task.sleep(for: .milliseconds(1_400))
        paused = true
    }
}

// MARK: - 2. Dirt dial

private struct RouteLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 16, y: rect.maxY - 24))
        path.addCurve(
            to: CGPoint(x: rect.midX - 10, y: rect.midY - 6),
            control1: CGPoint(x: rect.minX + 52, y: rect.maxY - 70),
            control2: CGPoint(x: rect.minX + 42, y: rect.midY + 26)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - 22, y: rect.minY + 26),
            control1: CGPoint(x: rect.midX + 30, y: rect.midY - 44),
            control2: CGPoint(x: rect.maxX - 78, y: rect.minY + 8)
        )
        return path
    }
}

/// Draws the line, settles on a mixed dirt share, then flips **allow unknown** on
/// and pushes the dash — and the number — most of the way to fully dirt.
struct DirtDialArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var progress: CGFloat = 0
    @State private var dirtPercent = 0
    @State private var unknownOn = false
    @State private var ticker: Task<Void, Never>?

    private var dashStart: CGFloat { unknownOn ? 0.03 : 0.16 }
    private var dashEnd: CGFloat { unknownOn ? 0.97 : 0.16 + 0.62 * progress }

    var body: some View {
        IllustrationStage {
            ZStack {
                RouteLine()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white.opacity(0.22), style: .init(lineWidth: 10, lineCap: .round))

                RouteLine()
                    .trim(from: dashStart, to: max(dashStart, dashEnd))
                    .stroke(
                        DirtTheme.orange,
                        style: .init(lineWidth: 10, lineCap: .round, dash: [11, 7])
                    )

                badges
            }
            .padding(.horizontal, DirtSpace.section)
        }
        .onChange(of: isActive, initial: true) { _, active in
            ticker?.cancel()
            guard active else { return }
            ticker = Task { await play() }
        }
        .onDisappear { ticker?.cancel() }
    }

    private var badges: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("\(dirtPercent)% DIRT")
                .font(.dirtUI(16, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(DirtTheme.onOrange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DirtTheme.orange, in: Capsule())

            Text("UNKNOWN ACCESS ON")
                .font(.dirtUI(11, weight: .heavy))
                .foregroundStyle(DirtTheme.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(DirtTheme.orange.opacity(0.7), lineWidth: 1))
                .opacity(unknownOn ? 1 : 0)
                .offset(y: unknownOn ? 0 : 4)
        }
        // Under the curve, which sweeps up to the right and leaves this corner clear.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 4)
    }

    private func play() async {
        guard !reduceMotion else {
            progress = 1
            dirtPercent = 94
            unknownOn = true
            return
        }

        progress = 0
        dirtPercent = 0
        unknownOn = false

        withAnimation(.easeInOut(duration: 1.05)) { progress = 1 }
        await tick(to: 58, over: 0.75, after: 0.35)

        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.5)) { unknownOn = true }
        await tick(to: 94, over: 0.5, after: 0.1)
    }

    /// Counts the badge up in step with the stroke so the number feels measured.
    private func tick(to target: Int, over duration: Double, after delay: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        let from = dirtPercent
        guard target > from else { return }
        let stepDelay = UInt64(duration * 1_000_000_000) / UInt64(target - from)
        for value in (from + 1)...target {
            guard !Task.isCancelled else { return }
            dirtPercent = value
            try? await Task.sleep(nanoseconds: stepDelay)
        }
    }
}

// MARK: - 3. Crew

/// Beacons for the crew, plus the two things riders actually do with them:
/// message a rider and receive a status.
struct CrewBeaconArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ring: CGFloat = 0
    @State private var chipsIn = false

    private let riders: [(x: CGFloat, y: CGFloat, delay: Double)] = [
        (-84, 10, 0.0),
        (-14, -30, 0.3),
        (62, 26, 0.6)
    ]

    var body: some View {
        IllustrationStage {
            ZStack {
                ForEach(Array(riders.enumerated()), id: \.offset) { index, rider in
                    beacon(delay: rider.delay, isYou: index == 0)
                        .offset(x: rider.x, y: rider.y)
                }

                messageBubble
                    .offset(x: 58, y: -66)
                    .opacity(chipsIn ? 1 : 0)
                    .scaleEffect(chipsIn ? 1 : 0.8, anchor: .bottomLeading)

                statusChip
                    .offset(x: -52, y: 68)
                    .opacity(chipsIn ? 1 : 0)
                    .offset(y: chipsIn ? 0 : 6)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            guard active else { return }
            play()
        }
    }

    private var messageBubble: some View {
        Text("Gate ahead")
            .font(.dirtUI(12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 10, weight: .bold))
            Text("NEEDS FUEL")
                .font(.dirtUI(11, weight: .heavy))
        }
        .foregroundStyle(DirtTheme.onOrange)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(DirtTheme.orange, in: Capsule())
    }

    private func beacon(delay: Double, isYou: Bool) -> some View {
        let tint = isYou ? DirtTheme.orange : Color.white

        return ZStack {
            Circle()
                .stroke(tint.opacity(0.5 * (1 - ring)), lineWidth: 2)
                .frame(width: 22 + 46 * ring, height: 22 + 46 * ring)
            Circle()
                .fill(tint)
                .frame(width: isYou ? 18 : 14, height: isYou ? 18 : 14)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(delay),
            value: ring
        )
    }

    private func play() {
        guard !reduceMotion else {
            ring = 0.4
            chipsIn = true
            return
        }
        ring = 0
        chipsIn = false
        DispatchQueue.main.async { ring = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.45)) {
            chipsIn = true
        }
    }
}
