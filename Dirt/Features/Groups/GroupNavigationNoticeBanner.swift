import SwiftUI

struct GroupMapNoticesHost: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(spacing: DirtSpace.tight) {
            if let notice = app.planner.groupNavigationNotice {
                GroupNavigationNoticeBanner(
                    notice: notice,
                    onDismiss: app.planner.dismissGroupNavigationNotice
                )
            }
            if !app.groups.peerAlerts.isEmpty {
                PeerAlertStack(
                    alerts: app.groups.peerAlerts,
                    onFocus: app.groups.focusPeerAlert,
                    onDismiss: app.groups.dismissPeerAlert
                )
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.planner.groupNavigationNotice?.id)
    }
}

/// Stop-triggered group routing is intentionally quiet while either motorcycle
/// is moving. This confirmation stays until the rider dismisses it.
struct GroupNavigationNoticeBanner: View {
    let notice: GroupNavigationNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DirtSpace.inner) {
            Image(systemName: symbolName)
                .font(.headline.weight(.bold))
                .foregroundStyle(DirtTheme.orange)
                .frame(width: DirtHit.min, height: DirtHit.min)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text(notice.title)
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                Text(notice.message)
                    .font(DirtType.helper)
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: DirtHit.min, height: DirtHit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss route update")
        }
        .padding(.leading, DirtSpace.tight)
        .padding(.trailing, DirtSpace.hairGap)
        .padding(.vertical, DirtSpace.tight)
        .frame(minHeight: DirtHit.control)
        .background(
            DirtTheme.chrome,
            in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.orange.opacity(0.75), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbolName: String {
        switch notice.kind {
        case .updated: return "arrow.triangle.2.circlepath"
        case .lastKnown: return "location.slash.fill"
        case .needsReview: return "fuelpump.fill"
        }
    }
}
