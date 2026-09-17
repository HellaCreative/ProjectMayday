import SwiftUI

/// Frosted card that appears after a search result is selected and the
/// map has flown to the pin. Offers "Route here" or "Add waypoint".
struct SearchConfirmationCard: View {
    let result: LocationSearchService.Result
    let onRoute: () -> Void
    let onWaypoint: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            actions
        }
        .padding(16)
        .frame(width: 268)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 20, y: 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) { dismissButton }
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.85)
                    .combined(with: .opacity)
                    .animation(.spring(duration: 0.36, bounce: 0.25)),
                removal: .scale(scale: 0.92)
                    .combined(with: .opacity)
                    .animation(.easeIn(duration: 0.16))
            )
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DirtTheme.ink)
                .lineLimit(2)

            HStack(spacing: 4) {
                Text(result.address)
                    .lineLimit(1)
                if let dist = result.distanceMeters {
                    Text("·")
                    Text(LocationSearchView.formatDistance(dist))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(DirtTheme.muted)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                onRoute()
            } label: {
                Label("Route here", systemImage: "location.north.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(DirtTheme.onOrange)
                    .background(DirtTheme.orange, in: RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
            }

            Button {
                onWaypoint()
            } label: {
                Label("Waypoint", systemImage: "plus")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(DirtTheme.chrome, in: RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
            }
        }
        .buttonStyle(DirtPressStyle())
    }

    // MARK: - Dismiss

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DirtTheme.muted)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(Color(.systemGray5).opacity(0.6))
                )
        }
        .padding(8)
        .accessibilityLabel("Dismiss")
    }
}
