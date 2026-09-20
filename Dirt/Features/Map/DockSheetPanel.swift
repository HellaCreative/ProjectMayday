import SwiftUI

/// Shared spring for Route / Layers / Group panels behind the dock.
enum DockSheetMotion {
    static var spring: Animation { DirtMotion.sheet }

    /// Portrait: rise from bottom. Landscape: slide in from the dock edge.
    static func transition(dockLeading: Bool?) -> AnyTransition {
        guard let dockLeading else {
            return .asymmetric(
                insertion: .move(edge: .bottom),
                removal: .move(edge: .bottom)
            )
        }
        let edge: Edge = dockLeading ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: edge),
            removal: .move(edge: edge)
        )
    }

    static var transition: AnyTransition { transition(dockLeading: nil) }

    /// Clears interactive content from under the sticky portrait dock. Measured from
    /// the safe-area bottom, and the dock now hangs lower into the home-indicator
    /// strip, so this is smaller than when the dock floated 40pt off the edge.
    static let dockClearance: CGFloat = 78

    /// Gap between the dock's outer edge and the physical bottom of the screen. The
    /// dock deliberately hangs into the home-indicator strip so the sheet behind it
    /// can run all the way to the edge.
    static let dockBottomGap: CGFloat = 18

    /// Outer landscape gutter reserved for the hardware Island. Tabs and the
    /// wordmark sit in the rail beside it — nothing draws into this column.
    static let landscapeIslandColumn: CGFloat = 50

    /// Inner landscape rail for logo + dock tabs.
    static let landscapeDockRailWidth: CGFloat = 78

    /// Full landscape dock. Island phones include the outer gutter; notch/SE do not.
    static func landscapeDockWidth(hasIslandColumn: Bool) -> CGFloat {
        landscapeDockRailWidth + (hasIslandColumn ? landscapeIslandColumn : 0)
    }

    /// Inner padding for dock tabs (Figma landscape-primary).
    static let landscapeDockEndPadding: CGFloat = 47

    /// Drawers include the strip under the dock. 55% (10% wider than half)
    /// so Start Ride and other CTAs keep readable width in landscape.
    static let landscapeMaxDrawerFraction: CGFloat = 0.55

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
/// Profile and Groups can drag like a system sheet: slide up for more, slide
/// down, swipe to close. Layers opens tall with the same swipe-to-close handle.
struct DockSheetPanel<Content: View>: View {
    /// Fixed height as a fraction of the screen, or the **collapsed** detent when
    /// `expandedHeightFraction` is set. Also the **maximum** when `fitsContent` is true.
    var heightFraction: CGFloat = 0.58
    /// When true, portrait collapsed height hugs measured content between a short
    /// minimum and `heightFraction`, plus `contentBreathing`.
    var fitsContent: Bool = false
    /// Absolute minimum portrait panel height when fitting (sits above the dock).
    var minContentHeight: CGFloat = 220
    /// Extra chrome above measured scroll content (inline nav title + top pad).
    var contentChromeHeight: CGFloat = 56
    /// Visible glass under the last content row so the collapsed detent is not flush.
    var contentBreathing: CGFloat = 0
    /// When set, the portrait sheet drags between `heightFraction` and this fraction.
    var expandedHeightFraction: CGFloat? = nil
    var showsDragIndicator: Bool = false
    /// When set, drawer is a full-height side panel that extends under the vertical dock.
    var landscapeDockLeading: Bool? = nil
    /// Island phones keep an empty outer column so tabs never sit on the cutout.
    var landscapeHasIslandColumn: Bool = false
    /// Thin glass — the Layers look is the sheet standard. Groupings use `groupingFill`.
    var material: Material = DirtTheme.sheetMaterial
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var measuredContentHeight: CGFloat = 0
    @State private var isExpanded = false
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if let dockLeading = landscapeDockLeading {
                landscapeSide(geo: geo, dockLeading: dockLeading)
            } else {
                portraitBottom(geo: geo)
            }
        }
        .allowsHitTesting(true)
        .accessibilityAction(.escape, onDismiss)
        .onPreferenceChange(DockSheetContentHeightKey.self) { measuredContentHeight = $0 }
    }

    // MARK: - Portrait

    private func portraitBottom(geo: GeometryProxy) -> some View {
        let collapsed = collapsedHeight(in: geo)
        let expanded = geo.size.height * (expandedHeightFraction ?? heightFraction)
        let base = isExpanded ? max(collapsed, expanded) : collapsed
        let panelHeight = min(max(base - dragTranslation, 140), geo.size.height)

        return VStack(spacing: 0) {
            if showsDragIndicator {
                grabber
            }
            content()
                .dirtSheetContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, showsDragIndicator ? 4 : 14)
        }
        .padding(.bottom, DockSheetMotion.dockClearance)
        .frame(width: geo.size.width, height: panelHeight, alignment: .top)
        .preference(key: PlannerSheetHeightKey.self, value: panelHeight)
        .clipShape(portraitShape)
        .background(alignment: .top) {
            portraitShape
                .fill(material)
                .overlay(portraitShape.stroke(DirtTheme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(dragTranslation == 0 ? DirtMotion.sheet : nil, value: panelHeight)
        .animation(DirtMotion.sheet, value: isExpanded)
    }

    private func collapsedHeight(in geo: GeometryProxy) -> CGFloat {
        // Interactive sheets (Profile / Groups) honor the requested fraction so
        // a 60% Groups detent is actually 60%. Fixed Layers still keeps map above.
        let fractionCap: CGFloat
        if expandedHeightFraction != nil {
            fractionCap = geo.size.height * heightFraction
        } else {
            fractionCap = min(
                geo.size.height * heightFraction,
                geo.size.height - (heightFraction < 1 ? 380 : 0)
            )
        }
        guard fitsContent else { return fractionCap }
        let minPanel = min(
            fractionCap,
            minContentHeight + contentChromeHeight + DockSheetMotion.dockClearance
        )
        let desired = measuredContentHeight > 0
            ? measuredContentHeight + contentChromeHeight + DockSheetMotion.dockClearance + 14 + contentBreathing
            : minPanel
        return min(max(desired, minPanel), fractionCap)
    }

    private var grabber: some View {
        Capsule()
            .fill(DirtTheme.muted.opacity(0.42))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(sheetDrag)
            .accessibilityLabel("Resize sheet")
            .accessibilityHint("Slide up for more, slide down to close")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Close") { onDismiss() }
    }

    private var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                dragTranslation = 0
                if translation > 120 || predicted > 180 {
                    DirtMotion.medium()
                    onDismiss()
                } else if translation < -36 {
                    if !isExpanded {
                        DirtMotion.light()
                    }
                    withAnimation(DirtMotion.sheet) { isExpanded = true }
                } else if translation > 36, isExpanded {
                    DirtMotion.light()
                    withAnimation(DirtMotion.sheet) { isExpanded = false }
                }
            }
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
        let dockW = DockSheetMotion.landscapeDockWidth(hasIslandColumn: landscapeHasIslandColumn)

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
        .background(material, in: sideShape(dockLeading: dockLeading))
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
