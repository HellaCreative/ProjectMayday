import SwiftUI

/// Six swipeable slides between the splash and the map. Sells *why* DIRT exists to
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
        case brand, dial, loop, fuel, offline, crew

        var title: String {
            switch self {
            case .brand: "Leave the pavement behind"
            case .dial: "Dial in how much dirt"
            case .loop: "Take the long way home"
            case .fuel: "Make room for the next stop"
            case .offline: "Take your maps with you"
            case .crew: "Ride with your crew"
            }
        }

        var body: String {
            switch self {
            case .brand:
                "DIRT is built for dual-sport riders — the ones who'd rather log gravel, forest road and two-track than asphalt."
            case .dial:
                "Choose Clean, Balanced or Dirt. Adjust ride wander and your road preferences to shape the journey."
            case .loop:
                "Pick a direction, a distance, a round trip from where you are."
            case .fuel:
                "Set your range. DIRT notifies you when fuel is running low — then you can route to a station. It does not drop fuel stops onto your line."
            case .offline:
                "Download regional maps before you leave coverage. Keep your packs up to date and prepare your route before heading out."
            case .crew:
                "Share live locations with your riding group and send in-app status alerts while DIRT stays connected. Precise Location makes navigation and sharing dependable."
            }
        }
    }

    var body: some View {
        ZStack {
            Color(dirtHex: 0x0B0C0E).ignoresSafeArea()

            LinearGradient(
                colors: [Color(dirtHex: 0x0B0C0E), Color(dirtHex: 0x1A1408)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RideBackdropVideo(playing: page == 0)
                .opacity(page == 0 ? 1 : 0)

            // Keep type and chrome readable over the ride plate.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(page == 0 ? 0.38 : 0), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 88)
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [.clear, Color(dirtHex: 0x0B0C0E).opacity(page == 0 ? 0.78 : 0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: page)

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
            .opacity(page == 0 ? 0 : 1)
            .accessibilityHidden(page == 0)
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
        VStack(alignment: .leading, spacing: 0) {
            art(for: slide)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slide == .brand ? .center : .top)

            VStack(alignment: .leading, spacing: DirtSpace.tight) {
                Text(slide.title)
                    .font(.dirtUI(28, weight: .heavy))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(slide.body)
                    .font(.dirtUI(16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DirtSpace.section)
        }
        .padding(.horizontal, DirtSpace.section)
        .padding(.bottom, DirtSpace.inner)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    @ViewBuilder
    private func art(for slide: Slide) -> some View {
        let isActive = page == slide.rawValue
        switch slide {
        case .brand: LogoBuildArt(isActive: isActive)
        case .dial: DirtDialArt(isActive: isActive)
        case .loop: IntroFeatureArt(symbol: "arrow.triangle.2.circlepath", caption: "DIRECTION. DISTANCE. HOME.")
        case .fuel: FuelNotifyArt()
        case .offline: IntroFeatureArt(symbol: "map.fill", caption: "PREPARE BEFORE YOU GO.")
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
                DirtMotion.medium()
                onFinished()
            } else {
                DirtMotion.light()
                withAnimation(reduceMotion ? nil : DirtMotion.sheet) {
                    page += 1
                }
            }
        } label: {
            HStack(spacing: DirtSpace.tight) {
                Text(isLast ? "Start riding" : "Next")
                if isLast {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DirtCTAStyle.brand())
        .shadow(
            color: isLast ? DirtTheme.orange.opacity(0.38) : .clear,
            radius: isLast ? 16 : 0,
            y: isLast ? 6 : 0
        )
        .accessibilityHint(isLast ? "Finishes the intro and opens the map" : "Shows the next slide")
    }
}

/// Large feature mark with room between the icon and the copy below.
struct IntroFeatureArt: View {
    let symbol: String
    let caption: String

    var body: some View {
        VStack(spacing: DirtSpace.row) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 128, weight: .medium))
                .foregroundStyle(DirtTheme.orange)
                .symbolRenderingMode(.hierarchical)
            Text(caption)
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

/// Fuel is a notification + optional reroute, not pins DIRT drops on the line.
struct FuelNotifyArt: View {
    var body: some View {
        VStack(spacing: DirtSpace.row) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: DirtSpace.inner) {
                HStack(alignment: .top, spacing: DirtSpace.inner) {
                    Image(systemName: "fuelpump.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(DirtTheme.orange)
                        .frame(width: DirtHit.min, height: DirtHit.min)
                    VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                        Text("Fuel running low")
                            .font(DirtType.rowTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                        Text("About 30 km of usable range left.")
                            .font(DirtType.helper)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                HStack(spacing: DirtSpace.tight) {
                    Text("Route to a station")
                        .font(DirtType.chip)
                        .fontWeight(.bold)
                        .foregroundStyle(DirtTheme.onOrange)
                        .padding(.horizontal, DirtSpace.row)
                        .frame(minHeight: DirtHit.min)
                        .background(DirtTheme.orange, in: Capsule())
                    Text("Not now")
                        .font(DirtType.chip)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, DirtSpace.inner)
                        .frame(minHeight: DirtHit.min)
                }
            }
            .padding(DirtSpace.row)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                    .stroke(DirtTheme.orange.opacity(0.45), lineWidth: 1)
            )

            Text("YOUR TANK. YOUR CALL.")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
