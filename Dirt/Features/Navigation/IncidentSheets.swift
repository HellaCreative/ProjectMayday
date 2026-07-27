import SwiftUI

/// Report → recovery → confirm flow, presented over the map during navigation.
/// Web parity: bottom sheets that never place route points and never replace
/// the route without explicit confirmation.
struct IncidentFlowOverlay: View {
    @Environment(AppEnvironment.self) private var app

    private var incidents: IncidentRecoveryModel { app.incidents }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    // Scrim tap only backs out of the category step; recovery
                    // decisions require an explicit button.
                    if incidents.step == .categories { incidents.dismiss() }
                }

            card
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.black.opacity(0.15))
                .frame(width: 42, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            switch incidents.step {
            case .hidden:
                EmptyView()
            case .categories:
                categoriesStep
            case .actions:
                actionsStep
            case .confirm:
                confirmStep
            case let .working(message):
                workingStep(message)
            }
        }
        .frame(maxWidth: .infinity)
        .background(DirtTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
    }

    // MARK: Step 1 — categories

    private var categoriesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Report what's ahead", sub: "One tap. No typing. We log it against your current route.")

            VStack(spacing: 6) {
                ForEach(RouteIncidentCategory.allCases) { category in
                    Button {
                        incidents.submitReport(category)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(category.color)
                                .frame(width: 10, height: 10)
                            Text(category.title)
                                .font(.dirtUI(14, weight: .bold))
                                .foregroundStyle(DirtTheme.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.black.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }

            if let failure = incidents.failureMessage {
                failureText(failure)
            }

            cancelButton("Cancel") { incidents.dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Step 2 — recovery actions

    private var actionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Report logged", sub: "Pick how you want to get clear. Your route won't change until you confirm.")

            if let report = incidents.activeReport {
                HStack(spacing: 10) {
                    Circle().fill(report.category.color).frame(width: 10, height: 10)
                    Text(report.category.title)
                        .font(.dirtUI(12, weight: .bold))
                        .foregroundStyle(DirtTheme.ink)
                    Spacer()
                    Text("UNVERIFIED")
                        .font(.dirtMono(9, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DirtTheme.wash)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(spacing: 6) {
                ForEach(IncidentRecoveryModel.RecoveryAction.allCases) { action in
                    Button {
                        incidents.choose(action)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(.dirtUI(14, weight: .heavy))
                                .foregroundStyle(action == .endStage ? DirtTheme.danger : DirtTheme.ink)
                            Text(action.subtitle)
                                .font(.dirtUI(11))
                                .foregroundStyle(DirtTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.black.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }

            if let failure = incidents.failureMessage {
                failureText(failure)
            }

            cancelButton("Close") { incidents.dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Step 3 — confirm replacement

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Replace route?", sub: nil)

            if let preview = incidents.preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.headline)
                        .font(.dirtUI(14, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                    Text(preview.detail)
                        .font(.dirtUI(12))
                        .foregroundStyle(DirtTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(DirtTheme.wash)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    incidents.keepCurrentRoute()
                } label: {
                    Text("Keep current route")
                        .font(.dirtUI(12, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(DirtTheme.wash)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button {
                    incidents.applyPreview()
                } label: {
                    Text("Apply route")
                        .font(.dirtUI(12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(DirtTheme.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func workingStep(_ message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(DirtTheme.orange)
            Text(message)
                .font(.dirtUI(13, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    // MARK: Pieces

    private func header(_ title: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.dirtUI(18, weight: .heavy))
                .foregroundStyle(DirtTheme.ink)
            if let sub {
                Text(sub)
                    .font(.dirtUI(12))
                    .foregroundStyle(DirtTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func failureText(_ message: String) -> some View {
        Text(message)
            .font(.dirtUI(12, weight: .semibold))
            .foregroundStyle(DirtTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cancelButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dirtUI(12, weight: .heavy))
                .foregroundStyle(DirtTheme.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(DirtTheme.wash)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
