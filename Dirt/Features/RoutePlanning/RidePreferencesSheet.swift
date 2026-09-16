import SwiftUI

struct RidePreferencesSheet: View {
    let initial: RidePreferences
    let onApply: (RidePreferences) -> Void
    var onClose: () -> Void = {}
    @State private var draft: RidePreferences

    init(
        initial: RidePreferences,
        onApply: @escaping (RidePreferences) -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.initial = initial
        self.onApply = onApply
        self.onClose = onClose
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(DirtTheme.orange)
                Text("Your Ride")
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

            Text("These choices apply to the whole route, including the roads between fuel stops.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DirtSpace.inner) {
                Text("\(Int(draft.wander * 100))%")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.ink)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .leading)
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

            Toggle("Avoid cities and towns", isOn: $draft.avoidCities)
            Toggle("Avoid highways", isOn: $draft.avoidHighways)

            Text("A road may still be needed to reach a waypoint or a fuel stop.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onApply(draft.normalized)
                withAnimation(.easeInOut(duration: 0.18)) { onClose() }
            } label: {
                Text("Apply to route").frame(maxWidth: .infinity)
            }
            .buttonStyle(DirtCTAStyle.brand())
        }
        .font(DirtType.rowTitle)
        .tint(DirtTheme.orange)
        .dirtTopAffordancePanel()
    }
}
