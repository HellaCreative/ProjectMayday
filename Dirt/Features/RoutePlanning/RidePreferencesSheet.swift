import SwiftUI

/// The same floating map panel used by the fuel controls. Changes are committed
/// together on Done so adjusting several controls rebuilds the ride only once.
struct RidePreferencesSheet: View {
    let onApply: (RidePreferences) -> Void
    @State private var draft: RidePreferences

    init(initial: RidePreferences, onApply: @escaping (RidePreferences) -> Void) {
        self.onApply = onApply
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(DirtTheme.orange)
                    .accessibilityHidden(true)
                Text("Your ride")
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                Spacer(minLength: 0)
                Button("Done") { onApply(draft.normalized) }
                    .font(DirtType.chip)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.orange)
                    .frame(minHeight: DirtHit.min)
            }

            VStack(alignment: .leading, spacing: DirtSpace.inner) {
                Text("Ride wander")
                    .font(DirtType.rowTitle)
                HStack(spacing: DirtSpace.inner) {
                    Text("\(Int(draft.wander * 100))%")
                        .font(DirtType.metricInline)
                        .foregroundStyle(DirtTheme.ink)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .leading)
                        .accessibilityHidden(true)
                    Slider(value: $draft.wander, in: 0...1, step: 0.05)
                        .tint(DirtTheme.orange)
                        .accessibilityLabel("Ride wander")
                        .accessibilityValue("\(Int(draft.wander * 100)) percent")
                }
                HStack {
                    Text("More direct")
                    Spacer()
                    Text("More exploring")
                }
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
            }

            Toggle("Avoid cities and towns", isOn: $draft.avoidCities)
            Toggle("Avoid highways", isOn: $draft.avoidHighways)
            Toggle("Avoid ferries", isOn: $draft.avoidFerries)
        }
        .font(DirtType.rowTitle)
        .foregroundStyle(DirtTheme.ink)
        .tint(DirtTheme.orange)
        .modifier(RouteControlsPanelStyle())
    }
}

/// One surface treatment for both map control panels.
struct RouteControlsPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: 420)
            .background(DirtTheme.sheetMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }
}
