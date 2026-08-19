import SwiftUI

/// Shared spring for Route / Layers / Profile / Group panels behind the dock.
enum DockSheetMotion {
    static let spring = Animation.spring(response: 0.46, dampingFraction: 0.74)

    /// Portrait: rise from bottom. Landscape: slide in from the dock edge.
    static func transition(dockLeading: Bool?) -> AnyTransition {
        guard let dockLeading else {
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            )
        }
        let edge: Edge = dockLeading ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge).combined(with: .opacity)
        )
    }

    static var transition: AnyTransition { transition(dockLeading: nil) }

    /// Clears interactive content from under the sticky portrait dock. Measured from
    /// the safe-area bottom, and the dock now hangs lower into the home-indicator
    /// strip, so this is smaller than when the dock floated 40pt off the edge.
    static let dockClearance: CGFloat = 66

    /// Gap between the dock's outer edge and the physical bottom of the screen. The
    /// dock deliberately hangs into the home-indicator strip so the sheet behind it
    /// can run all the way to the edge.
    static let dockBottomGap: CGFloat = 18

    /// Figma landscape vertical dock width (flush to non-island edge).
    static let landscapeDockWidth: CGFloat = 78

    /// Inner padding for dock tabs (Figma landscape-primary).
    static let landscapeDockEndPadding: CGFloat = 47

    /// Drawers may take at most half the screen (includes area under the dock).
    static let landscapeMaxDrawerFraction: CGFloat = 0.5

    /// Recenter sits this far outside the route drawer’s open edge.
    static let landscapeRecenterGap: CGFloat = 24

    /// Gap between portrait route sheet top and compact map controls.
    static let portraitRouteControlsGap: CGFloat = 10
}

/// Portrait route-planner sheet height — used to park recenter / fit-route just above it.
enum PlannerSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Intrinsic scroll content height for adaptive dock sheets (Groups list).
enum DockSheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Panel that sits *behind* the dock — portrait (bottom) or landscape (side).
/// Dismiss by tapping the dock tab again (no grab handle).
struct DockSheetPanel<Content: View>: View {
    /// Fixed height as a fraction of the screen, or the **maximum** when `fitsContent` is true.
    var heightFraction: CGFloat = 0.58
    /// When true, portrait height hugs measured content between a short minimum and `heightFraction`.
    var fitsContent: Bool = false
    /// Absolute minimum portrait panel height when fitting (sits above the dock).
    var minContentHeight: CGFloat = 220
    /// Extra chrome above measured scroll content (inline nav title + top pad).
    var contentChromeHeight: CGFloat = 56
    /// When set, drawer is a full-height side panel that extends under the vertical dock.
    var landscapeDockLeading: Bool? = nil
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var measuredContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let dockLeading = landscapeDockLeading {
                landscapeSide(geo: geo, dockLeading: dockLeading)
            } else {
                portraitBottom(geo: geo)
            }
        }
        .allowsHitTesting(true)
        .onPreferenceChange(DockSheetContentHeightKey.self) { measuredContentHeight = $0 }
    }

    // MARK: - Portrait

    private func portraitBottom(geo: GeometryProxy) -> some View {
        let maxPanel = min(geo.size.height * heightFraction, geo.size.height - 48)
        let panelHeight: CGFloat
        if fitsContent {
            let minPanel = min(
                maxPanel,
                minContentHeight + contentChromeHeight + DockSheetMotion.dockClearance
            )
            let desired = measuredContentHeight > 0
                ? measuredContentHeight + contentChromeHeight + DockSheetMotion.dockClearance + 14
                : minPanel
            panelHeight = min(max(desired, minPanel), maxPanel)
        } else {
            panelHeight = maxPanel
        }

        return VStack(spacing: 0) {
            content()
                .dirtSheetContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)
        }
        .padding(.bottom, DockSheetMotion.dockClearance)
        .frame(width: geo.size.width, height: panelHeight, alignment: .top)
        .clipShape(portraitShape)
        // Surface only — content keeps its safe-area layout while the material runs
        // past the home indicator, so no map shows under an open sheet.
        .background(alignment: .top) {
            portraitShape
                .fill(DirtTheme.sheetMaterial)
                .overlay(portraitShape.stroke(DirtTheme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(DockSheetMotion.spring, value: panelHeight)
    }

    private var portraitShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DirtRadius.sheet,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: DirtRadius.sheet,
            style: .continuous
        )
    }

    // MARK: - Landscape side (extends under dock)

    private func landscapeSide(geo: GeometryProxy, dockLeading: Bool) -> some View {
        // Half-screen total, including the strip under the dock (portrait parity).
        let panelW = geo.size.width * DockSheetMotion.landscapeMaxDrawerFraction
        let dockW = DockSheetMotion.landscapeDockWidth

        return HStack(spacing: 0) {
            if dockLeading {
                sidePanel(width: panelW, dockLeading: true, dockClearance: dockW)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                sidePanel(width: panelW, dockLeading: false, dockClearance: dockW)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidePanel(width: CGFloat, dockLeading: Bool, dockClearance: CGFloat) -> some View {
        VStack(spacing: 0) {
            content()
                .dirtSheetContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.vertical, 12)
        .padding(.leading, dockLeading ? dockClearance + 10 : 14)
        .padding(.trailing, dockLeading ? 14 : dockClearance + 10)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(DirtTheme.sheetMaterial, in: sideShape(dockLeading: dockLeading))
        .overlay(sideShape(dockLeading: dockLeading).stroke(DirtTheme.hairline, lineWidth: 1))
        .clipShape(sideShape(dockLeading: dockLeading))
        .shadow(
            color: .black.opacity(0.22),
            radius: 18,
            x: dockLeading ? 8 : -8,
            y: 0
        )
    }

    /// Open-map edge rounded; dock edge square so the surface runs under the rail.
    private func sideShape(dockLeading: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: dockLeading ? 0 : DirtRadius.card,
            bottomLeadingRadius: dockLeading ? 0 : DirtRadius.card,
            bottomTrailingRadius: dockLeading ? DirtRadius.card : 0,
            topTrailingRadius: dockLeading ? DirtRadius.card : 0,
            style: .continuous
        )
    }
}
