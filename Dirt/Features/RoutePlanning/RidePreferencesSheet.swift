import SwiftUI

/// Ride-shape controls in the same top-down glass panel as fuel range.
struct RidePreferencesSheet: View {
    let onApply: (RidePreferences) -> Void
    let onClose: () -> Void
    @State private var draft: RidePreferences
    @State private var committed: RidePreferences

    init(
        initial: RidePreferences,
        onApply: @escaping (RidePreferences) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onApply = onApply
        self.onClose = onClose
        _draft = State(initialValue: initial)
        _committed = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(DirtTheme.orange)
                Text("Your ride")
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                Spacer(minLength: 0)
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.18)) { onClose() }
                }
                .font(DirtType.chip)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.orange)
                .frame(minHeight: DirtHit.min)
            }

            Text("Shape the journey")
                .font(DirtType.rowTitle)
                .foregroundStyle(DirtTheme.ink)
            Text("These choices apply to the whole route, including the roads between fuel stops.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DirtSpace.inner) {
                Text("\(Int(draft.wander * 100))%")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.ink)
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .leading)
                    .accessibilityHidden(true)
                Slider(value: $draft.wander, in: 0...1, step: 0.05) { editing in
                    if !editing { commitIfNeeded() }
                }
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

            Toggle("Avoid cities and towns", isOn: $draft.avoidCities)
                .font(DirtType.rowTitle)
                .tint(DirtTheme.orange)
                .onChange(of: draft.avoidCities) { _, _ in commitIfNeeded() }
            Toggle("Avoid highways", isOn: $draft.avoidHighways)
                .font(DirtType.rowTitle)
                .tint(DirtTheme.orange)
                .onChange(of: draft.avoidHighways) { _, _ in commitIfNeeded() }

            Text("A road may still be needed to reach a waypoint or a fuel stop.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(DirtTheme.sheetMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }

    private func commitIfNeeded() {
        let next = draft.normalized
        draft = next
        guard next != committed else { return }
        committed = next
        onApply(next)
    }
}
