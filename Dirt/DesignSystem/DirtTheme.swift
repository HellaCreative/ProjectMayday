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
    /// Green exclusive to Start / End navigation CTAs.
    static let navGreen = Color(dirtHex: 0x147A56)
    static let exportGray = Color(dirtHex: 0x616872)
    static let danger = Color(dirtHex: 0xD83B42)
    static let dirtMix = Color(dirtHex: 0x3A9DFF)
    static let pavedMix = Color(dirtHex: 0xFDB003)
    static let pavedLine = Color(dirtHex: 0x303A45)
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
    var body: some View {
        HStack(spacing: 6) {
            (Text("DIRT").italic().fontWeight(.black) + Text(".").italic().fontWeight(.black).foregroundColor(DirtTheme.orange))
                .font(.dirtUI(16, weight: .black))
                .foregroundStyle(.white)
            Text("MAYDAY")
                .font(.dirtMono(9, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DirtTheme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DirtTheme.chromeBorder, lineWidth: 1))
    }
}
