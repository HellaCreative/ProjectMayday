import SwiftData
import SwiftUI

/// After End this ride → Yes. Geometry is the GPS ride, never the plan.
struct SaveRiddenRouteSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext
    let candidate: RiddenRouteSaveCandidate
    let onDone: () -> Void

    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(candidate: RiddenRouteSaveCandidate, onDone: @escaping () -> Void) {
        self.candidate = candidate
        self.onDone = onDone
        _name = State(initialValue: candidate.suggestedName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirtSpace.group) {
                Capsule()
                    .fill(DirtTheme.ink.opacity(0.18))
                    .frame(width: 42, height: 5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, DirtSpace.inner)

                VStack(alignment: .leading, spacing: DirtSpace.tight) {
                    Text("Would you like to save your route from today?")
                        .font(DirtType.title)
                        .foregroundStyle(DirtTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text("This is the line you rode — detours, fuel stops, Continue, and Turn around included. Your planned route stays in the list as it is.")
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: DirtSpace.tight) {
                    TextField("Name this ride", text: $name)
                        .font(DirtType.rowTitle)
                        .foregroundStyle(DirtTheme.ink)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .padding(.horizontal, DirtSpace.row)
                        .frame(minHeight: DirtHit.control)
                        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                                .stroke(nameFocused ? DirtTheme.orange : DirtTheme.hairline, lineWidth: 1)
                        )
                        .accessibilityLabel("Ride name")

                    Text(String(format: "%.1f km ridden", candidate.distanceMeters / 1000))
                        .font(DirtType.metricInline)
                        .foregroundStyle(DirtTheme.muted)
                }

                VStack(spacing: DirtSpace.tight) {
                    Button("Save to Saved Routes", action: save)
                        .buttonStyle(DirtCTAStyle.brand())
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Save ridden route")

                    Button("Not now", action: onDone)
                        .font(DirtType.rowTitle)
                        .foregroundStyle(DirtTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                }
            }
            .padding(.horizontal, DirtSpace.row)
            .padding(.bottom, DirtSpace.row)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DirtTheme.sheetMaterial)
        .onAppear { nameFocused = true }
    }

    private func save() {
        app.planner.saveRiddenRoute(
            named: name,
            coordinates: candidate.coordinates,
            distanceMeters: candidate.distanceMeters,
            context: modelContext
        )
        onDone()
    }
}

/// Occasional ask when Contribute is off. Opens Profile — never uploads from here.
struct ContributeNudgeSheet: View {
    let onOpenProfile: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DirtSpace.group) {
            Capsule()
                .fill(DirtTheme.ink.opacity(0.18))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, DirtSpace.inner)

            VStack(alignment: .leading, spacing: DirtSpace.tight) {
                Text("Want to participate?")
                    .font(DirtType.title)
                    .foregroundStyle(DirtTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("Helps validate DIRT routes for other riders. Contribute lives in Profile. When it’s on, End Ride silently uploads the pack roads we already classified — never a GPS trail.")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: DirtSpace.tight) {
                Button("Open Profile", action: onOpenProfile)
                    .buttonStyle(DirtCTAStyle.brand())
                    .accessibilityHint("Opens Profile to turn on Contribute")

                Button("Not now", action: onDismiss)
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: DirtHit.min)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DirtSpace.row)
        .padding(.bottom, DirtSpace.row)
        .background(DirtTheme.sheetMaterial)
    }
}
