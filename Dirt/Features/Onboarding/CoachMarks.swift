import SwiftUI

/// Chrome a coach mark can point at. Views publish their frame with
/// `.coachTarget(_:)`, so the arrow follows the real layout in both portrait and
/// landscape instead of hard-coding dock geometry.
enum CoachTarget: Hashable {
    case routeDock
    case routeCard
    case groupDock
    case profileDock

    /// Dock cells get a highlight ring; a whole sheet does not, because ringing a
    /// sheet is just a rectangle around most of the screen.
    var wantsRing: Bool { self != .routeCard }
}

struct CoachTargetKey: PreferenceKey {
    static let defaultValue: [CoachTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [CoachTarget: Anchor<CGRect>],
        nextValue: () -> [CoachTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Optional so callers inside a `ForEach` over unrelated chrome can tag just
    /// the one item that matters without publishing a bogus anchor for the rest.
    @ViewBuilder
    func coachTarget(_ target: CoachTarget?) -> some View {
        if let target {
            anchorPreference(key: CoachTargetKey.self, value: .bounds) { [target: $0] }
        } else {
            self
        }
    }
}

/// The first-ride tour. Ordered as the shortest path to a real route — From here,
/// not Plan a route — then the crew tools, then the account.
enum CoachStep: Int, CaseIterable {
    /// Ring the Route dock cell. Clears itself when the planner opens.
    case openRoute
    /// Planner is open with no destination yet.
    case dropPin
    /// A line exists: point at Start, and mention Plan a route for more waypoints.
    case ride
    /// Ring the Group dock cell.
    case crew
    /// Ring the Profile dock cell and land on the trial.
    case account

    var target: CoachTarget {
        switch self {
        case .openRoute, .dropPin, .ride: .routeDock
        case .crew: .groupDock
        case .account: .profileDock
        }
    }

    var title: String {
        switch self {
        case .openRoute: "Start where you are"
        case .dropPin: "Now pick where you're going"
        case .ride: "That's your line"
        case .crew: "Ride with your crew"
        case .account: "Your account and trial"
        }
    }

    var body: String {
        switch self {
        case .openRoute:
            "Your location is already set as the start. Tap Route to begin."
        case .dropPin:
            "Tap the map to drop your destination — or long-press a road to snap it. DIRT routes there from where you're standing."
        case .ride:
            "Hit the green Start to ride it. Or switch to Plan a route to keep adding waypoints."
            case .crew:
                "Create a group to get a code, or join with a friend's — then you'll see each other on the map. This is the one part that needs an account."
            case .account:
                "Sign in with Apple and start your free trial in Profile. Voice cues and keep-awake live here too."
        }
    }

    /// Steps the rider completes by acting on the app need no button; the action is
    /// the confirmation.
    var showsConfirm: Bool {
        switch self {
        case .openRoute, .dropPin: false
        case .ride, .crew, .account: true
        }
    }

    var isLast: Bool { self == .account }
}

/// Non-blocking coach marks: a ring, an arrow and a card. The map and chrome
/// underneath stay live, because the point of the tour is to get the rider
/// *using* the thing, not watching a slideshow.
struct CoachMarksOverlay: View {
    let step: CoachStep
    let targetRect: CGRect?
    var onAdvance: () -> Void
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var showsRing: Bool { step.target.wantsRing }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let targetRect {
                    if showsRing {
                        ring(targetRect)
                            .allowsHitTesting(false)
                    }

                    card(in: proxy.size, target: targetRect)
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func ring(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DirtTheme.orange, lineWidth: 2.5)
            .frame(width: rect.width + 10, height: rect.height + 10)
            .opacity(pulse ? 0.35 : 1)
            .scaleEffect(pulse ? 1.06 : 1)
            .position(x: rect.midX, y: rect.midY)
    }

    private func card(in size: CGSize, target: CGRect) -> some View {
        // Sit on whichever side of the target has room; the dock and the planner
        // are both bottom chrome, so in practice this puts the card over the map.
        let arrowDown = target.midY > size.height / 2
        let width = min(size.width - 2 * DirtSpace.section, 360)

        return VStack(spacing: 0) {
            if !arrowDown { arrowRow(pointingDown: false, cardWidth: width, in: size, target: target) }

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.dirtUI(16, weight: .heavy))
                    .foregroundStyle(DirtTheme.orange)

                Text(step.body)
                    .font(.dirtUI(14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DirtSpace.inner) {
                    stepDots

                    Spacer(minLength: 0)

                    Button("Skip tour", action: onSkip)
                        .font(.dirtUI(13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(minHeight: DirtHit.min)
                        .contentShape(Rectangle())

                    if step.showsConfirm {
                        Button(step.isLast ? "Done" : "Next", action: onAdvance)
                            .font(.dirtUI(14, weight: .heavy))
                            .foregroundStyle(DirtTheme.onOrange)
                            .padding(.horizontal, 16)
                            .frame(minHeight: DirtHit.min)
                            .background(DirtTheme.orange, in: Capsule())
                            .contentShape(Capsule())
                    }
                }
                .padding(.top, 2)
            }
            .padding(DirtSpace.row)
            .background {
                ZStack {
                    Rectangle().fill(DirtTheme.chromeMaterial)
                    Rectangle().fill(DirtTheme.chromeScrim)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DirtTheme.orange.opacity(0.55), lineWidth: 1)
            )

            if arrowDown { arrowRow(pointingDown: true, cardWidth: width, in: size, target: target) }
        }
        .frame(width: width, alignment: .leading)
        .position(
            x: size.width / 2,
            y: arrowDown ? target.minY - 84 : target.maxY + 84
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.title). \(step.body)")
    }

    /// The card is screen-centred but the target usually is not — a dock item sits
    /// in one of four cells — so the arrow is nudged along the card edge to sit
    /// over whatever it is pointing at.
    private func arrowRow(
        pointingDown: Bool,
        cardWidth: CGFloat,
        in size: CGSize,
        target: CGRect
    ) -> some View {
        let arrowWidth: CGFloat = 18
        let cardOriginX = (size.width - cardWidth) / 2
        let inset = max(
            DirtSpace.row,
            min(cardWidth - DirtSpace.row - arrowWidth, target.midX - cardOriginX - arrowWidth / 2)
        )

        return Image(systemName: pointingDown ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
            .font(.system(size: arrowWidth))
            .foregroundStyle(DirtTheme.orange)
            .offset(y: pointingDown ? -2 : 2)
            .padding(.leading, inset)
            .frame(width: cardWidth, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var stepDots: some View {
        HStack(spacing: 5) {
            ForEach(CoachStep.allCases, id: \.rawValue) { candidate in
                Circle()
                    .fill(candidate == step ? DirtTheme.orange : Color.white.opacity(0.28))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(CoachStep.allCases.count)")
    }
}
