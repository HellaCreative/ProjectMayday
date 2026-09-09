import SwiftUI

struct RidePreferencesSheet: View {
    let initial: RidePreferences
    let onApply: (RidePreferences) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RidePreferences

    init(initial: RidePreferences, onApply: @escaping (RidePreferences) -> Void) {
        self.initial = initial
        self.onApply = onApply
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(title: "Your ride", onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: DirtSpace.group) {
                    VStack(alignment: .leading, spacing: DirtSpace.tight) {
                        Text("Shape the journey")
                            .font(DirtType.title).foregroundStyle(DirtTheme.ink)
                        Text("These choices apply to the whole route, including the roads between fuel stops. Custom choices currently need online planning.")
                            .font(DirtType.helper).foregroundStyle(DirtTheme.muted)
                    }
                    VStack(alignment: .leading, spacing: DirtSpace.inner) {
                        HStack {
                            Text("Ride wander").font(DirtType.rowTitle)
                            Spacer()
                            Text("\(Int(draft.wander * 100))%")
                                .font(DirtType.metricInline).foregroundStyle(DirtTheme.muted)
                                .accessibilityHidden(true)
                        }
                        Slider(value: $draft.wander, in: 0...1, step: 0.05)
                            .tint(DirtTheme.orange)
                            .accessibilityLabel("Ride wander")
                            .accessibilityValue("\(Int(draft.wander * 100)) percent")
                        HStack {
                            Text("More direct")
                            Spacer()
                            Text("More exploring")
                        }.font(DirtType.helper).foregroundStyle(DirtTheme.muted)
                    }
                    .padding(DirtSpace.row)
                    .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control))
                    VStack(spacing: DirtSpace.row) {
                        Toggle("Avoid cities and towns", isOn: $draft.avoidCities)
                        Divider()
                        Toggle("Avoid highways", isOn: $draft.avoidHighways)
                    }
                    .font(DirtType.rowTitle)
                    .tint(DirtTheme.orange)
                    .padding(DirtSpace.row)
                    .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control))
                    Text("A road may still be needed to reach a waypoint or a fuel stop.")
                        .font(DirtType.helper).foregroundStyle(DirtTheme.muted)
                }.padding(DirtSpace.group)
            }
            Button {
                onApply(draft.normalized)
                dismiss()
            } label: {
                Text("Apply to route").frame(maxWidth: .infinity)
            }
            .buttonStyle(DirtCTAStyle.brand())
            .padding(DirtSpace.group)
        }
        .background(DirtTheme.sheetMaterial)
    }
}
