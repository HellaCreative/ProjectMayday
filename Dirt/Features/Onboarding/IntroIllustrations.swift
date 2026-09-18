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

// MARK: - 3. Long way home

/// Round trip from where you are: a tight loop vs the long way that makes room.
/// The path draws once and a rider tick comes home. No bounce, no forever spin.
struct LongWayArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var youIn = false
    @State private var shortProgress: CGFloat = 0
    @State private var longProgress: CGFloat = 0
    @State private var riderProgress: CGFloat = 0
    @State private var homeIn = false
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        IllustrationStage {
            VStack(spacing: DirtSpace.row) {
                Spacer(minLength: 0)
                GeometryReader { geo in
                    let rect = CGRect(origin: .zero, size: geo.size)
                    let longPath = LongLoop(scale: 1).path(in: rect)
                    let shortPath = LongLoop(scale: 0.42).path(in: rect)
                    let start = LongLoop.home(in: rect)
                    let riderAt = point(on: longPath, start: start, t: riderProgress)

                    ZStack {
                        shortPath.stroke(
                            Color.white.opacity(0.18),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [5, 7])
                        )
                        .opacity(shortProgress)

                        longPath
                            .trim(from: 0, to: longProgress)
                            .stroke(
                                DirtTheme.orange,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                            )

                        Circle()
                            .fill(DirtTheme.orange)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                            .position(start)
                            .opacity(youIn ? 1 : 0)
                            .scaleEffect(youIn ? 1 : 0.6)

                        if riderProgress > 0.02, riderProgress < 0.98 {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 11, height: 11)
                                .shadow(color: DirtTheme.orange.opacity(0.7), radius: 6)
                                .position(riderAt)
                        }

                        Text("YOU")
                            .font(.dirtUI(11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                            .position(x: start.x, y: start.y + 22)
                            .opacity(youIn ? 1 : 0)

                        Text("THE LONG WAY")
                            .font(.dirtUI(11, weight: .heavy))
                            .foregroundStyle(DirtTheme.onOrange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(DirtTheme.orange, in: Capsule())
                            .position(x: rect.midX, y: max(18, rect.minY + 22))
                            .opacity(homeIn ? 1 : 0)
                    }
                }
                .frame(maxWidth: 340, maxHeight: .infinity)

                Text("DIRECTION. DISTANCE. HOME.")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            playTask?.cancel()
            guard active else { return }
            playTask = Task { await play() }
        }
        .onDisappear { playTask?.cancel() }
    }

    private func point(on path: Path, start: CGPoint, t: CGFloat) -> CGPoint {
        guard t > 0 else { return start }
        return path.trimmedPath(from: 0, to: min(1, max(0.001, t))).currentPoint ?? start
    }

    private func play() async {
        guard !reduceMotion else {
            youIn = true
            shortProgress = 1
            longProgress = 1
            riderProgress = 1
            homeIn = true
            return
        }

        youIn = false
        shortProgress = 0
        longProgress = 0
        riderProgress = 0
        homeIn = false

        withAnimation(.easeOut(duration: 0.28)) { youIn = true }
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.35)) { shortProgress = 1 }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 1.05)) { longProgress = 1 }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 1.35)) { riderProgress = 1 }
        try? await Task.sleep(for: .milliseconds(720))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.35)) { homeIn = true }
    }
}

/// Closed loop from the home pin. `scale` < 1 is the tight ride; 1 is the long way.
private struct LongLoop: Shape {
    var scale: CGFloat

    func path(in rect: CGRect) -> Path {
        let home = Self.home(in: rect)
        let cx = home.x
        let cy = home.y - rect.height * 0.08
        let rx = rect.width * 0.42 * scale
        let ry = rect.height * 0.40 * scale
        var path = Path()
        path.move(to: home)
        path.addCurve(
            to: CGPoint(x: cx - rx, y: cy),
            control1: CGPoint(x: home.x - rx * 0.15, y: home.y - ry * 0.35),
            control2: CGPoint(x: cx - rx, y: cy + ry * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: cx, y: cy - ry),
            control1: CGPoint(x: cx - rx, y: cy - ry * 0.55),
            control2: CGPoint(x: cx - rx * 0.55, y: cy - ry)
        )
        path.addCurve(
            to: CGPoint(x: cx + rx, y: cy),
            control1: CGPoint(x: cx + rx * 0.55, y: cy - ry),
            control2: CGPoint(x: cx + rx, y: cy - ry * 0.55)
        )
        path.addCurve(
            to: home,
            control1: CGPoint(x: cx + rx, y: cy + ry * 0.55),
            control2: CGPoint(x: home.x + rx * 0.15, y: home.y - ry * 0.35)
        )
        return path
    }

    static func home(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.maxY - 36)
    }
}

// MARK: - 4. Prepare / download maps

/// Tiles land in the pack the way a download does — top to bottom, then ready.
struct MapDownloadArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = 4
    private let rows = 3

    @State private var outline = false
    @State private var arrowIn = false
    @State private var filled = 0
    @State private var ready = false
    @State private var playTask: Task<Void, Never>?

    private var tileCount: Int { columns * rows }

    var body: some View {
        IllustrationStage {
            VStack(spacing: DirtSpace.row) {
                Spacer(minLength: 0)

                ZStack(alignment: .top) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(DirtTheme.orange)
                        .offset(y: arrowIn ? 0 : -14)
                        .opacity(arrowIn ? 1 : 0)
                        .padding(.bottom, 8)

                    VStack(spacing: 10) {
                        Color.clear.frame(height: 28)

                        mapCard
                            .opacity(outline ? 1 : 0)
                            .offset(y: outline ? 0 : 8)

                        HStack(spacing: 6) {
                            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 12, weight: .bold))
                            Text(ready ? "READY TO RIDE" : "DOWNLOADING MAPS")
                                .font(.dirtUI(11, weight: .heavy))
                        }
                        .foregroundStyle(ready ? DirtTheme.orange : .white.opacity(0.55))
                        .opacity(outline ? 1 : 0)
                    }
                }
                .frame(maxWidth: 280)

                Text("PREPARE BEFORE YOU GO.")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            playTask?.cancel()
            guard active else { return }
            playTask = Task { await play() }
        }
        .onDisappear { playTask?.cancel() }
    }

    private var mapCard: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
                spacing: 6
            ) {
                ForEach(0..<tileCount, id: \.self) { index in
                    let on = filled > index
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? DirtTheme.orange.opacity(0.92) : Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white.opacity(on ? 0 : 0.16), lineWidth: 1)
                        )
                        .frame(height: 36)
                }
            }

            GeometryReader { geo in
                let t = tileCount == 0 ? 0 : CGFloat(filled) / CGFloat(tileCount)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(DirtTheme.orange)
                        .frame(width: geo.size.width * t)
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func play() async {
        guard !reduceMotion else {
            outline = true
            arrowIn = true
            filled = tileCount
            ready = true
            return
        }

        outline = false
        arrowIn = false
        filled = 0
        ready = false

        withAnimation(.easeOut(duration: 0.32)) { outline = true }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.4)) { arrowIn = true }

        for next in 1...tileCount {
            try? await Task.sleep(for: .milliseconds(95))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { filled = next }
        }

        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.28)) { ready = true }
    }
}

// MARK: - 5. Crew

/// Beacons come up as a net: riders land, one radio ping each, then a message
/// and a status. Plays once and rests — no forever pulse.
struct CrewBeaconArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visible = [false, false, false]
    @State private var link: CGFloat = 0
    @State private var ping: [CGFloat] = [0, 0, 0]
    @State private var pingFade: [CGFloat] = [0, 0, 0]
    @State private var restHalo = false
    @State private var messageIn = false
    @State private var statusIn = false
    @State private var playTask: Task<Void, Never>?

    private let riders: [(x: CGFloat, y: CGFloat)] = [
        (-84, 12),
        (-10, -34),
        (70, 22)
    ]

    var body: some View {
        IllustrationStage {
            ZStack {
                ForEach(1..<riders.count, id: \.self) { index in
                    Path { path in
                        path.move(to: CGPoint(x: riders[0].x, y: riders[0].y))
                        path.addLine(to: CGPoint(x: riders[index].x, y: riders[index].y))
                    }
                    .trim(from: 0, to: link)
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
                }

                ForEach(Array(riders.enumerated()), id: \.offset) { index, rider in
                    beacon(index: index, isYou: index == 0)
                        .offset(x: rider.x, y: rider.y)
                        .opacity(visible[index] ? 1 : 0)
                        .scaleEffect(visible[index] ? 1 : 0.7)
                }

                messageBubble
                    .offset(x: 62, y: -70)
                    .opacity(messageIn ? 1 : 0)
                    .scaleEffect(messageIn ? 1 : 0.84, anchor: .bottomLeading)

                statusChip
                    .offset(x: -56, y: 74)
                    .opacity(statusIn ? 1 : 0)
                    .offset(y: statusIn ? 0 : 8)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            playTask?.cancel()
            guard active else { return }
            playTask = Task { await play() }
        }
        .onDisappear { playTask?.cancel() }
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

    private func beacon(index: Int, isYou: Bool) -> some View {
        let tint = isYou ? DirtTheme.orange : Color.white
        let ring = ping[index]
        let fade = pingFade[index]

        return ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .opacity(restHalo ? 1 : 0)

            Circle()
                .stroke(tint.opacity(0.7 * fade), lineWidth: 2)
                .frame(width: 18 + 42 * ring, height: 18 + 42 * ring)

            Circle()
                .fill(tint)
                .frame(width: isYou ? 18 : 14, height: isYou ? 18 : 14)
        }
    }

    private func play() async {
        guard !reduceMotion else {
            visible = [true, true, true]
            link = 1
            ping = [0, 0, 0]
            pingFade = [0, 0, 0]
            restHalo = true
            messageIn = true
            statusIn = true
            return
        }

        visible = [false, false, false]
        link = 0
        ping = [0, 0, 0]
        pingFade = [0, 0, 0]
        restHalo = false
        messageIn = false
        statusIn = false

        for index in 0..<riders.count {
            try? await Task.sleep(for: .milliseconds(index == 0 ? 80 : 160))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                var next = visible
                next[index] = true
                visible = next
            }
        }

        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.55)) { link = 1 }

        for index in 0..<riders.count {
            try? await Task.sleep(for: .milliseconds(index == 0 ? 120 : 220))
            guard !Task.isCancelled else { return }
            await radioPing(index)
        }

        withAnimation(.easeOut(duration: 0.3)) { restHalo = true }

        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.78)) { messageIn = true }

        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.78)) { statusIn = true }
    }

    private func radioPing(_ index: Int) async {
        var start = ping
        start[index] = 0
        ping = start
        var fadeOn = pingFade
        fadeOn[index] = 1
        pingFade = fadeOn
        withAnimation(.easeOut(duration: 0.9)) {
            var nextPing = ping
            nextPing[index] = 1
            ping = nextPing
            var nextFade = pingFade
            nextFade[index] = 0
            pingFade = nextFade
        }
        try? await Task.sleep(for: .milliseconds(280))
    }
}
