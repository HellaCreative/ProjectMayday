import SwiftUI

struct GroupMapNoticesHost: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: app.planner.groupNavigationNotice?.id)
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

/// Peer distress banners while a group ride is live.
struct PeerAlertStack: View {
    let alerts: [PeerAlertBanner]
    let onFocus: (PeerAlertBanner) -> Void
    let onDismiss: (String) -> Void

    var body: some View {
        VStack(spacing: DirtSpace.tight) {
            ForEach(alerts.prefix(3)) { alert in
                let isBreakdown = GroupsViewModel.isMechanicalDistressStatus(alert.status)
                HStack(alignment: .center, spacing: DirtSpace.tight) {
                    Button {
                        onFocus(alert)
                    } label: {
                        VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                            Text(alert.title)
                                .font(DirtType.rowTitle)
                                .fontWeight(.bold)
                                .foregroundStyle(isBreakdown ? .white : DirtTheme.ink)
                            Text(alert.subtitle)
                                .font(DirtType.helper)
                                .foregroundStyle(isBreakdown ? .white.opacity(0.9) : DirtTheme.muted)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the rider's last known location")
                    Button {
                        onDismiss(alert.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(isBreakdown ? .white.opacity(0.85) : DirtTheme.muted)
                            .frame(width: DirtHit.min, height: DirtHit.min)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss alert")
                }
                .padding(.leading, DirtSpace.inner)
                .padding(.trailing, DirtSpace.tight)
                .padding(.vertical, DirtSpace.tight)
                .frame(minHeight: DirtHit.control)
                .background(background(for: alert.status), in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                        .stroke(border(for: alert.status), lineWidth: 1)
                )
            }
        }
    }

    private func background(for status: String) -> Color {
        switch status {
        case "breakdown", "flat_tire", "dead_battery", "unrepairable": return Color(dirtHex: 0xDC6803)
        case "injured": return Color(dirtHex: 0xC1122F).opacity(0.12)
        case "stuck": return Color(dirtHex: 0x7C3AED).opacity(0.12)
        default: return DirtTheme.rowFill
        }
    }

    private func border(for status: String) -> Color {
        switch status {
        case "breakdown", "flat_tire", "dead_battery", "unrepairable": return Color(dirtHex: 0xDC6803)
        case "injured": return Color(dirtHex: 0xC1122F).opacity(0.35)
        case "stuck": return Color(dirtHex: 0x7C3AED).opacity(0.35)
        default: return DirtTheme.hairline
        }
    }
}
