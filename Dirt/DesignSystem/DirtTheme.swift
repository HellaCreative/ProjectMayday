import SwiftUI
import UIKit

extension Color {
    init(dirtHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Appearance-aware brand token. Light values match the shipped chrome exactly,
    /// so nothing moves while `DirtApp` still pins `.light`; dark is ready for when it doesn't.
    init(dirtLight light: UInt32, dark: UInt32, opacity: Double = 1) {
        self.init(
            UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: opacity
                )
            }
        )
    }
}

/// DIRT chrome tokens.
enum DirtTheme {
    static let orange = Color(dirtHex: 0xFF8000)
    static let orangeHover = Color(dirtHex: 0xF07800)
    static let orangePressed = Color(dirtHex: 0xFF8000)
    /// Orange text and symbols on light surfaces; lighter counterpart in dark mode.
    static let action = orange
    /// The foreground for anything filled with `orange`. Measured on #FF7A00: white is
    /// **2.61:1** and fails AA at every text size, this is **6.80:1**.
    ///
    /// Deliberately a fixed dark rather than `ink`: an orange fill stays orange in dark
    /// mode, so its text must stay dark. `ink` flips to #F2F4F7 and lands back at ~2.7:1.
    ///
    /// White *is* correct on the other brand fills — navGreen 5.32:1, danger 4.54:1,
    /// exportGray 5.63:1, chrome 17.77:1. Orange is the only one that can't carry it.
    static let onOrange = Color(dirtHex: 0x16181C)
    /// Dock “route still on map” while the planner sheet is minimized (not selected).
    static let orangeSoft = Color(dirtHex: 0xFFB35C)
    static let navigationSurface = Color(dirtHex: 0x202820)
    static let chrome = Color(dirtHex: 0x16181C)
    static let chromeBorder = Color.white.opacity(0.12)
    static let ink = Color(dirtLight: 0x16181C, dark: 0xF2F4F7)
    static let muted = Color(dirtLight: 0x616872, dark: 0x9AA3AE)
    static let sheet = Color(dirtLight: 0xFFFFFF, dark: 0x1B1E23, opacity: 0.97)
    static let wash = Color(dirtLight: 0xF1F2F4, dark: 0x262A31)

    /// Hairline that separates a sheet or control from the map behind it.
    static let hairline = Color(dirtLight: 0x16181C, dark: 0xFFFFFF, opacity: 0.10)

    // MARK: - Surfaces over live map

    /// Dock and modal sheets. Thin glass so the map still reads underneath —
    /// the Layers look is the sheet standard. Groupings sit on `groupingFill`,
    /// not on a second material.
    static let sheetMaterial: Material = .thinMaterial
    /// Map controls and dock: thin material carrying a dark scrim, so white glyphs
    /// keep contrast over snow, water, and satellite imagery alike.
    static let chromeMaterial: Material = .ultraThinMaterial
    /// Scrim strength over `chromeMaterial`; tuned to hold ≥4.5:1 for white glyphs.
    static let chromeScrim = Color(dirtHex: 0x16181C, opacity: 0.72)

    /// Opaque islands on thin glass. Sections, segments, and cards use this so
    /// they contrast off the map showing through the sheet — not more glass.
    static let groupingFill = Color(dirtLight: 0xFFFFFF, dark: 0x2B3037, opacity: 0.94)
    /// Rows and cards on a glass sheet. Same fill as `groupingFill` — one language.
    static let rowFill = groupingFill
    /// Nav HUD primary text on chrome (Figma `--panel/2`).
    static let panelText = Color(dirtHex: 0xEEF3F7)
    /// Nav HUD metric values on chrome (Figma `--bg`).
    static let panelValue = Color(dirtHex: 0xF7F9FB)
    /// Green exclusive to Start / End navigation CTAs.
    static let navGreen = Color(dirtHex: 0x147A56)
    static let exportGray = Color(dirtHex: 0x616872)
    static let danger = Color(dirtHex: 0xD83B42)
    /// Layers legend / basemap paved overlay (not selected-route paint).
    static let pavedLine = Color(dirtHex: 0x303A45)

    // Selected-route surface families. Rich, deep colors stay legible against
    // the white route casing; purple remains an independent access warning.
    static let routeAccess = Color(dirtHex: 0x54208F)
    static let routePaved = Color(dirtHex: 0x14161A)
    static let routeGravel = Color(dirtHex: 0xB56A00)
    static let routeLoose = Color(dirtHex: 0x6E2F16)
    static let routeUnknown = Color(dirtHex: 0x555A63)
    /// Transport connector rather than a road surface. Kept marine-blue so a
    /// ferry reads immediately over water without entering the Dirt/Paved mix.
    static let routeFerry = Color(dirtHex: 0x005A70)

    /// Nearby pack-network overlay — thinner, distinct from selected-route paint.
    static let overlayAccess = Color(dirtHex: 0x0A66C2)
    static let overlayGravel = Color(dirtHex: 0x5D6874)
    static let overlayTrack = routeLoose

    /// Dirt % text + mix bar — matches map dirt (warm brand orange).
    static let dirtMix = orange
    /// Paved % text + mix bar — matches the four-family map legend.
    static let pavedMix = routePaved

    /// Paint bucket for a graph surface/track class.
    static func routePaintColor(for surfaceKey: String) -> Color {
        switch surfaceKey.lowercased() {
        case "paved":
            return routePaved
        case "gravel":
            return routeGravel
        case "loose":
            return routeLoose
        case "unknown":
            return routeUnknown
        case "unknown_access":
            return routeAccess
        case "ferry":
            return routeFerry
        default:
            return routeUnknown
        }
    }
}

/// Corner radii. Controls and sheets share one family so chrome reads as one system.
enum DirtRadius {
    static let chip: CGFloat = 10
    static let control: CGFloat = 12
    static let card: CGFloat = 14
    static let sheet: CGFloat = 22
}

/// Spacing scale. Tight inside a group, generous between groups.
enum DirtSpace {
    static let hairGap: CGFloat = 2
    static let tight: CGFloat = 6
    static let inner: CGFloat = 10
    static let row: CGFloat = 14
    static let group: CGFloat = 20
    static let section: CGFloat = 28
}

/// Minimum hit targets. 44 pt is the HIG floor, not a suggestion.
enum DirtHit {
    static let min: CGFloat = 44
    static let control: CGFloat = 50
}

/// Operate-mode motion: feedback and continuity, not page-load choreography.
/// Springs yield to a short ease when Reduce Motion is on.
enum DirtMotion {
    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Sheet enter / detent snap. Slight overshoot; Reduce Motion uses ease-out.
    static var sheet: Animation {
        reduceMotion
            ? .easeOut(duration: 0.22)
            : .spring(response: 0.36, dampingFraction: 0.86)
    }

    static var sheetExit: Animation {
        reduceMotion
            ? .easeIn(duration: 0.16)
            : .easeIn(duration: 0.20)
    }

    /// Fuel / Your Ride drop-in, zoom press, island appear.
    static var affordance: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.30, dampingFraction: 0.88)
    }

    /// Dock tab selection — a little bounce so the orange pill lands.
    static var dock: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.22)
            : .spring(response: 0.34, dampingFraction: 0.78)
    }

    /// Grouping islands entering the sheet.
    static var island: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.32, dampingFraction: 0.80)
    }

    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// Press scale for map chips and dock-adjacent controls.
struct DirtPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(DirtMotion.affordance, value: configuration.isPressed)
    }
}

/// Dynamic Type–aware semantic scale. Adopt these in sheets instead of fixed
/// `dirtUI(_:)` / `dirtMono(_:)` sizes so text follows the rider's reading size.
enum DirtType {
    /// Quiet, readable group heading.
    static let sectionLabel: Font = .system(.footnote, design: .default, weight: .semibold)
    /// Sheet or drawer title.
    static let title: Font = .system(.title3, design: .default, weight: .bold)
    /// Primary row label.
    static let rowTitle: Font = .system(.subheadline, design: .default, weight: .semibold)
    /// Supporting line under a row label.
    static let helper: Font = .system(.footnote, design: .default, weight: .regular)
    /// Chip / segment label.
    static let chip: Font = .system(.footnote, design: .default, weight: .semibold)
    /// Primary call to action.
    static let cta: Font = .system(.subheadline, design: .default, weight: .semibold)
    /// Headline metric (distance, dirt %).
    static let metric: Font = .system(.title3, design: .monospaced, weight: .bold)
    /// Inline metric beside a label.
    static let metricInline: Font = .system(.footnote, design: .monospaced, weight: .semibold)
}

/// Sheet and control surfaces over the live map.
extension View {
    /// Overlay chrome (HUD chips). Dock sheets use `sheetMaterial` on `DockSheetPanel`.
    func dirtSheetSurface(
        radius: CGFloat = DirtRadius.card,
        shadow: Bool = true
    ) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
            .shadow(color: shadow ? .black.opacity(0.16) : .clear, radius: 14, y: 6)
    }

    /// Opaque grouping on thin glass (cards, sections, unselected segments).
    func dirtGroupingSurface(radius: CGFloat = DirtRadius.control) -> some View {
        background(DirtTheme.groupingFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
    }

    /// Fuel range and Your Ride — glass windows that drop from the top of the map.
    func dirtTopAffordancePanel() -> some View {
        padding(DirtSpace.row)
            .frame(maxWidth: 420)
            .background(
                DirtTheme.sheetMaterial,
                in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }

    /// Dark glass used by map controls, the dock, and the brand chip. `tint` replaces
    /// the scrim for selected states so brand orange stays solid and unmistakable.
    /// A tint replaces the scrimmed glass with a solid orange fill, which can only carry
    /// dark glyphs — so the foreground is decided here rather than at the call site, where
    /// the two used to drift apart. Callers should not set their own `foregroundStyle`;
    /// an inner one wins over this and reintroduces white on orange.
    func dirtChromeSurface(
        radius: CGFloat = DirtRadius.control,
        tint: Color? = nil
    ) -> some View {
        foregroundStyle(tint == nil ? Color.white : DirtTheme.onOrange)
        .background {
            ZStack {
                if let tint {
                    Rectangle().fill(tint)
                } else {
                    Rectangle().fill(DirtTheme.chromeMaterial)
                    Rectangle().fill(DirtTheme.chromeScrim)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }

    /// Keeps dense map chrome from breaking its fixed 50 pt boxes at accessibility sizes.
    func dirtDenseChrome() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Sheet content sitting on `DockSheetPanel`'s material. `List` and `Form` paint
    /// `systemGroupedBackground`, and the navigation bar paints its own fill — both
    /// hide the material underneath. Every dock sheet applies this.
    func dirtSheetContent() -> some View {
        scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension Font {
    /// Martian Mono stand-in for metrics (distance, %, invite codes, cue meta).
    static func dirtMono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Archivo stand-in for UI copy.
    static func dirtUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Route CTA matrix: Save = black, Export = gray, Start = green.
struct DirtCTAStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white
    /// Shows a spinner in place of the label while work is in flight.
    var isLoading: Bool = false

    /// Brand-orange primary action, paired with the only foreground that passes AA on it.
    /// Use this instead of `DirtCTAStyle(fill: DirtTheme.orange)`, which inherits white.
    static func brand(isLoading: Bool = false) -> DirtCTAStyle {
        DirtCTAStyle(fill: DirtTheme.orange, foreground: DirtTheme.onOrange, isLoading: isLoading)
    }

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, fill: fill, foreground: foreground, isLoading: isLoading)
    }

    private struct Surface: View {
        let configuration: Configuration
        let fill: Color
        let foreground: Color
        let isLoading: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            ZStack {
                configuration.label
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foreground)
                }
            }
            .font(DirtType.cta)
            .multilineTextAlignment(.center)
            .padding(.vertical, DirtSpace.inner)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min)
            .padding(.horizontal, DirtSpace.row)
            .background(fill.opacity(configuration.isPressed ? 0.78 : 1))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

struct DirtSecondaryButtonStyle: ButtonStyle {
    var foreground: Color = DirtTheme.action

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, foreground: foreground)
    }

    private struct Surface: View {
        let configuration: Configuration
        let foreground: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(DirtType.rowTitle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DirtSpace.row)
                .padding(.vertical, DirtSpace.inner)
                .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                .foregroundStyle(foreground)
                .background(DirtTheme.groupingFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                        .stroke(DirtTheme.hairline, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: DirtRadius.control))
        }
    }
}

struct DirtChipStyle: ButtonStyle {
    var isActive: Bool
    /// Popovers and inline chrome where a 44 pt row would break the layout.
    var dense: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isActive: isActive, dense: dense)
    }

    private struct Surface: View {
        let configuration: Configuration
        let isActive: Bool
        let dense: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(DirtType.chip)
                .padding(.horizontal, dense ? DirtSpace.inner : DirtSpace.row)
                .frame(minHeight: dense ? 34 : DirtHit.min)
                .background(isActive ? DirtTheme.orange : DirtTheme.groupingFill)
                .foregroundStyle(isActive ? DirtTheme.onOrange : DirtTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous)
                        .stroke(
                            isActive ? DirtTheme.onOrange.opacity(0.25) : DirtTheme.hairline,
                            lineWidth: 1
                        )
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
        }
    }
}

/// Section heading shared by dock sheets and full-screen forms.
struct DirtSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DirtType.sectionLabel)
            .foregroundStyle(DirtTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title bar for a dock sheet or focused full-screen destination. `DockSheetPanel`
/// is already the container for map-aware panels, so those sheets don't need a
/// `NavigationStack` — and must not have one: its hosted navigation controller
/// paints an opaque background over the panel's material.
struct DirtSheetHeader: View {
    let title: String
    var titleFont: Font = DirtType.title
    /// Shown when the sheet is displaying a pushed-feeling detail view.
    var onBack: (() -> Void)?
    /// Shown when the surface owns the screen and needs an explicit escape.
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: DirtSpace.inner) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DirtTheme.action)
                        .frame(width: DirtHit.min, height: DirtHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Text(title)
                .font(titleFont)
                .foregroundStyle(DirtTheme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(width: DirtHit.min, height: DirtHit.min)
                        .background(DirtTheme.rowFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            } else if onBack != nil {
                Color.clear.frame(width: DirtHit.min, height: DirtHit.min)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
        .padding(.horizontal, DirtSpace.row)
        .padding(.top, DirtSpace.row)
        .padding(.bottom, DirtSpace.row)
    }
}

/// Hardware Dynamic Island — portrait iPhone 14 Pro and later.
/// Detected from the window's top safe-area inset (59pt). Notch phones are ~47pt.
/// Never invent an Island on SE, notch, or iPad.
enum DirtIsland {
    static let minimumTopInset: CGFloat = 59
    /// Hardware cutout size in portrait points.
    static let cutoutWidth: CGFloat = 126
    static let cutoutHeight: CGFloat = 37
    static let cutoutTop: CGFloat = 11

    static func isPresent(
        topInset: CGFloat,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
        isLandscape: Bool
    ) -> Bool {
        !isLandscape && idiom == .phone && topInset >= minimumTopInset
    }
}

struct BrandChip: View {
    @Environment(AppEnvironment.self) private var app

    private var edition: String {
        if AppConfig.backendEnvironment == .development { return "DEV" }
        return app.subscription.isSubscribed ? "PRO" : "FREE"
    }

    /// When set (nav top chrome), stretch the chrome box to match cue/speed height
    /// without enlarging the wordmark.
    var minHeight: CGFloat = 42
    /// Landscape: expand to the brand-column width so the left rail aligns.
    var fillsWidth: Bool = false
    /// Wordmark only, sitting in the Island bar — no nested chrome.
    var embedsInIsland: Bool = false

    /// Wordmark only — `DIRT.` (orange period). MAYDAY no longer sits in the chip.
    var body: some View {
        HStack(spacing: 0) {
            Text("DIRT")
                .italic()
                .fontWeight(.black)
                .foregroundStyle(.white)
            Text(".")
                .italic()
                .fontWeight(.black)
                .foregroundStyle(DirtTheme.orange)
            Text(edition)
                .font(.system(size: embedsInIsland ? 7 : 8, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, embedsInIsland ? 4 : 5)
                .padding(.vertical, embedsInIsland ? 2 : 3)
                .background(DirtTheme.orange, in: Capsule())
                .padding(.leading, embedsInIsland ? 5 : 6)
        }
        .font(.dirtUI(embedsInIsland ? 13 : 16, weight: .black))
        .padding(.horizontal, embedsInIsland ? 0 : 12)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: embedsInIsland ? DirtIsland.cutoutHeight : minHeight)
        .modifier(BrandChipChrome(embedsInIsland: embedsInIsland, minHeight: minHeight, fillsWidth: fillsWidth))
        .accessibilityLabel(
            AppConfig.backendEnvironment == .development ? "DIRT development" : "DIRT \(edition.lowercased())"
        )
    }
}

private struct BrandChipChrome: ViewModifier {
    var embedsInIsland: Bool
    var minHeight: CGFloat
    var fillsWidth: Bool

    func body(content: Content) -> some View {
        if embedsInIsland {
            content
        } else {
            content.dirtChromeSurface(radius: DirtRadius.chip)
        }
    }
}

/// One surface vocabulary across route controls and navigation.
enum DirtSurfaceIcon {
    /// Native menu rows retain brand tint instead of inheriting UIKit label black.
    static func menuImage(for title: String) -> Image {
        let symbol = UIImage(systemName: symbol(for: title))?
            .withTintColor(UIColor(DirtTheme.orange), renderingMode: .alwaysOriginal)
        return Image(uiImage: symbol ?? UIImage()).renderingMode(.original)
    }

    static func symbol(for title: String) -> String {
        let value = title.lowercased()
        if value.contains("ferry") { return "ferry" }
        if value.contains("unknown") { return "questionmark.diamond" }
        if value.contains("gravel") { return "circle.grid.3x3" }
        if value.contains("dirt") || value.contains("loose") || value.contains("sand") { return "mountain.2" }
        if value.contains("balanced") { return "arrow.triangle.branch" }
        return "road.lanes"
    }
}

/// Opaque dropdown affordance: the field stays legible above map-backed sheets.
extension View {
    func dirtDropdownSurface() -> some View {
        tint(DirtTheme.orange)
            .foregroundStyle(DirtTheme.orange)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(DirtTheme.groupingFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DirtTheme.hairline, lineWidth: 1))
    }
}
