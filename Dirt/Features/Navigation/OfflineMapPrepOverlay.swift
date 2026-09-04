import SwiftUI

/// Full-screen gate before navigation: download corridor maps, then a ready beat.
struct OfflineMapPrepOverlay: View {
    @Environment(AppEnvironment.self) private var app

    private var offline: OfflineTileManager { app.offline }
    private var graphPacks: GraphPackStore { app.graphPacks }
    private var planner: RoutePlannerModel { app.planner }

    @State private var readyPulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                card
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 22)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OFFLINE MAPS")
                .font(.dirtUI(11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(DirtTheme.orange)

            switch offline.phase {
            case .downloading(let completed, let total):
                downloadingContent(completed: completed, total: total)
            case .ready(let cached, let total):
                switch graphPacks.phase {
                case .downloading:
                    graphPackDownloadingContent()
                case .failed(let message):
                    graphPackFailedContent(message)
                default:
                    readyContent(cached: cached, total: total)
                }
            case .failed(let message):
                failedContent(message)
            case .idle:
                EmptyView()
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(DirtTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offline maps")
    }

    private func downloadingContent(completed: Int, total: Int) -> some View {
        let planning = total == 0
        let mostlyCached = total > 0 && completed >= total && offline.progress >= 0.99
        return VStack(alignment: .leading, spacing: 14) {
            Text(planning
                 ? "Preparing offline maps"
                 : (mostlyCached ? "Checking maps for this ride" : "Saving maps for the trail"))
                .font(.dirtUI(22, weight: .bold))
                .foregroundStyle(DirtTheme.ink)

            Text(planning
                 ? "Mapping the route corridor before the download begins."
                 : (mostlyCached
                    ? "This corridor is already on your phone. Confirming tiles, then you’re set."
                    : "Dual-sport country means no signal. We’re saving the first riding section before you roll."))
                .font(.dirtUI(14))
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if planning {
                    ProgressView()
                } else {
                    ProgressView(value: offline.progress)
                        .scaleEffect(x: 1, y: 1.4, anchor: .center)
                }
            }
            .tint(DirtTheme.orange)

            HStack {
                if planning {
                    Text("Building corridor")
                        .font(.dirtUI(13, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                } else {
                    Text("\(offline.progressPercent)%")
                        .font(.dirtMono(28, weight: .bold))
                        .foregroundStyle(DirtTheme.ink)
                        .contentTransition(.numericText())
                }
                Spacer()
                if !planning {
                    Text("\(completed) / \(total) tiles")
                        .font(.dirtMono(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.muted)
                }
            }

            cancelButton(topPadding: 4)
        }
    }

    private func readyContent(cached: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DirtTheme.navGreen.opacity(0.18))
                        .frame(width: 52, height: 52)
                        .scaleEffect(readyPulse ? 1.12 : 1.0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(DirtTheme.navGreen)
                        .symbolEffect(.bounce, value: readyPulse)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trail maps locked in")
                        .font(.dirtUI(22, weight: .bold))
                        .foregroundStyle(DirtTheme.ink)
                    Text(total > 0 ? "\(cached) corridor tiles ready offline." : "You’re set for this ride.")
                        .font(.dirtUI(13))
                        .foregroundStyle(DirtTheme.muted)
                    graphPackStatusLine
                }
            }
            .onAppear {
                readyPulse = true
            }

            Text(readyBlurb)
                .font(.dirtUI(14))
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                planner.beginRideAfterOfflineReady()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("BEGIN RIDE")
                        .tracking(0.6)
                }
                .font(.dirtUI(14, weight: .heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(DirtTheme.navGreen)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.top, 4)

            cancelButton(alignment: .center)
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Couldn’t finish offline maps")
                .font(.dirtUI(22, weight: .bold))
                .foregroundStyle(DirtTheme.ink)

            Text(message)
                .font(.dirtUI(14))
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                planner.retryOfflineMapPrep()
            } label: {
                Text("TRY AGAIN")
                    .font(.dirtUI(14, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(DirtTheme.onOrange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(DirtTheme.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                // Last resort — dual-sport default is offline-first, but don't
                // trap the rider if the trailhead has no usable signal left.
                planner.beginRideAfterOfflineReady()
            } label: {
                Text("Ride with live maps only")
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(DirtTheme.danger)
                    .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            cancelButton()
        }
    }

    private func graphPackDownloadingContent() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Locking routing for the bush")
                .font(.dirtUI(22, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
            Text("Maps are ready. Downloading the road network for your current province so you can reroute without cell service.")
                .font(.dirtUI(14))
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: max(graphPacks.progress, 0.05))
                .tint(DirtTheme.orange)
            cancelButton()
        }
    }

    private func graphPackFailedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Routing pack didn’t download")
                .font(.dirtUI(22, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
            Text(message)
                .font(.dirtUI(14))
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                planner.retryOfflineMapPrep()
            } label: {
                Text("TRY AGAIN")
                    .font(.dirtUI(14, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(DirtTheme.onOrange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(DirtTheme.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                planner.beginRideAfterOfflineReady()
            } label: {
                Text("Ride without offline rerouting")
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(DirtTheme.danger)
                    .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            cancelButton()
        }
    }

    /// Cancel shows up in four prep states. The target spans the card width so a
    /// gloved thumb at the trailhead isn't hunting for 13 pt of text.
    private func cancelButton(alignment: Alignment = .leading, topPadding: CGFloat = 0) -> some View {
        Button {
            planner.cancelOfflineMapPrep()
        } label: {
            Text("Cancel")
                .font(.dirtUI(13, weight: .semibold))
                .foregroundStyle(DirtTheme.muted)
                .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, topPadding)
    }

    @ViewBuilder
    private var graphPackStatusLine: some View {
        switch graphPacks.phase {
        case .ready:
            Text("Current province routing pack ready.")
                .font(.dirtUI(12, weight: .semibold))
                .foregroundStyle(DirtTheme.navGreen)
        case .skipped:
            Text("A routing pack for part of this ride is not published yet.")
                .font(.dirtUI(12))
                .foregroundStyle(DirtTheme.muted)
        case .failed:
            Text("Offline routing pack download failed.")
                .font(.dirtUI(12))
                .foregroundStyle(DirtTheme.danger)
        default:
            EmptyView()
        }
    }

    private var readyBlurb: String {
        if case .ready = graphPacks.phase {
            return "The first riding section and your current province are ready offline. Later sections and provinces are saved as you ride."
        }
        if !graphPacks.loadedRegionIds.isEmpty {
            return "The first riding section is saved. Packs already on this phone can handle offline detours as the ride continues."
        }
        return "The first riding section is saved. A later province may still require a live connection while its routing pack is acquired."
    }
}
