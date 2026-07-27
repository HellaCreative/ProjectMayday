import SwiftUI

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
}

/// DIRT web chrome tokens (docs/WEB-SPEC-FOR-IOS.md §1).
enum DirtTheme {
    static let orange = Color(dirtHex: 0xFF7A00)
    static let orangeHover = Color(dirtHex: 0xE56A00)
    static let orangePressed = Color(dirtHex: 0xC25400)
    static let chrome = Color(dirtHex: 0x16181C)
    static let chromeBorder = Color.white.opacity(0.12)
    static let ink = Color(dirtHex: 0x16181C)
    static let muted = Color(dirtHex: 0x616872)
    static let sheet = Color.white.opacity(0.97)
    static let wash = Color(dirtHex: 0xF1F2F4)
    /// Nav HUD primary text on chrome (Figma `--panel/2`).
    static let panelText = Color(dirtHex: 0xEEF3F7)
    /// Nav HUD metric values on chrome (Figma `--bg`).
    static let panelValue = Color(dirtHex: 0xF7F9FB)
    /// Green exclusive to Start / End navigation CTAs.
    static let navGreen = Color(dirtHex: 0x147A56)
    static let exportGray = Color(dirtHex: 0x616872)
    static let danger = Color(dirtHex: 0xD83B42)
    /// Dirt % text + mix bar (stats only — not map line colour).
    static let dirtMix = Color(dirtHex: 0x3A9DFF)
    /// Paved % text + mix bar (stats only — not map line colour).
    static let pavedMix = Color(dirtHex: 0xFDB003)
    /// Layers legend / basemap paved overlay (not selected-route paint).
    static let pavedLine = Color(dirtHex: 0x303A45)

    // Selected-route map paint — matches live web `route-network` match expression
    // (app/index.html). Stats colours (#3a9dff / #fdb003) are intentionally separate.
    static let routeAccess = Color(dirtHex: 0x0A66C2)
    static let routeGravel = Color(dirtHex: 0x5D6874)
    static let routeTrack = Color(dirtHex: 0x7C3AED)
    static let routePaved = Color(dirtHex: 0xFFB000)
    static let routeConnector = Color(dirtHex: 0xD22730)

    /// Paint bucket for a graph surface/track class (web `trackClass` match).
    static func routePaintColor(for surfaceKey: String) -> Color {
        switch surfaceKey.lowercased() {
        case "access", "resource":
            return routeAccess
        case "gravel", "unknown", "unpaved", "dirt":
            return routeGravel
        case "track", "double_track":
            return routeTrack
        case "connector":
            return routeConnector
        case "paved":
            return routePaved
        default:
            return routePaved
        }
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dirtUI(12, weight: .heavy))
            .textCase(.uppercase)
            .tracking(0.6)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct DirtChipStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dirtUI(12, weight: .bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? DirtTheme.orange : DirtTheme.wash)
            .foregroundStyle(isActive ? .white : DirtTheme.ink)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isActive ? .white.opacity(0.9) : .black.opacity(0.08), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct BrandChip: View {
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
        }
        .font(.dirtUI(16, weight: .black))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
        .background(DirtTheme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .accessibilityLabel("DIRT")
    }
}
