import SwiftUI

/// Three swipeable slides between the splash and the map. Sells *why* DIRT exists to
/// an adventure / dual-sport rider; the how-to lives in the coach marks over the real
/// interface, not here.
///
/// Replays on every cold launch, so a rider who has already seen it gets a skip that
/// says where it goes rather than a bare "Skip".
struct IntroCarouselView: View {
    /// Has the rider been through this before? Only changes the skip wording.
    var isReturning: Bool = false
    var onFinished: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Slide: Int, CaseIterable {
        case brand, dial, crew

        var title: String {
            switch self {
            case .brand: "Leave the pavement behind"
            case .dial: "Dial in how much dirt"
            case .crew: "Ride with your crew"
            }
        }

        var body: String {
            switch self {
            case .brand:
                "DIRT is built for dual-sport riders — the ones who'd rather log gravel, forest road and two-track than asphalt."
            case .dial:
                "Set the mix of pavement to dirt, or go fully dirt. OSM tracks stay on. Allow unknown only opens unproven paths."
            case .crew:
                "Find your riders on the map, route straight to a friend, message them, and get status alerts when someone stops."
            }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(dirtHex: 0x0B0C0E), Color(dirtHex: 0x1A1408)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                TabView(selection: $page) {
                    ForEach(Slide.allCases, id: \.rawValue) { slide in
                        slideBody(slide)
                            .tag(slide.rawValue)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                    .padding(.bottom, DirtSpace.row)

                advanceButton
                    .padding(.horizontal, DirtSpace.section)
                    .padding(.bottom, DirtSpace.section)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to DIRT, slide \(page + 1) of \(Slide.allCases.count)")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            HStack(spacing: 0) {
                Text("DIRT").italic().foregroundStyle(.white)
                Text(".").italic().foregroundStyle(DirtTheme.orange)
            }
            .font(.system(size: 20, weight: .black))
            .accessibilityLabel("DIRT")

            Spacer(minLength: 0)

            Button(isReturning ? "Skip to map" : "Skip", action: onFinished)
                .font(DirtType.rowTitle)
                .fontWeight(.semibold)
                .foregroundStyle(isReturning ? DirtTheme.orange : .white.opacity(0.7))
                .padding(.horizontal, isReturning ? 6 : 0)
                .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                .contentShape(Rectangle())
                .accessibilityHint("Skips the intro and opens the map")
        }
        .padding(.horizontal, DirtSpace.section)
        .padding(.top, DirtSpace.inner)
    }

    private func slideBody(_ slide: Slide) -> some View {
        VStack(alignment: .leading, spacing: DirtSpace.row) {
            Spacer(minLength: 0)

            art(for: slide)

            Text(slide.title)
                .font(.dirtUI(28, weight: .heavy))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(slide.body)
                .font(.dirtUI(16, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DirtSpace.section)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func art(for slide: Slide) -> some View {
        let isActive = page == slide.rawValue
        switch slide {
        case .brand: LogoBuildArt(isActive: isActive)
        case .dial: DirtDialArt(isActive: isActive)
        case .crew: CrewBeaconArt(isActive: isActive)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(Slide.allCases, id: \.rawValue) { slide in
                Capsule()
                    .fill(slide.rawValue == page ? DirtTheme.orange : Color.white.opacity(0.25))
                    .frame(width: slide.rawValue == page ? 22 : 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Slide \(page + 1) of \(Slide.allCases.count)")
    }

    private var isLast: Bool { page == Slide.allCases.count - 1 }

    private var advanceButton: some View {
        Button {
            if isLast {
                onFinished()
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    page += 1
                }
            }
        } label: {
            Text(isLast ? "Start riding" : "Next")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DirtCTAStyle.brand())
        .accessibilityHint(isLast ? "Finishes the intro" : "Shows the next slide")
    }
}
