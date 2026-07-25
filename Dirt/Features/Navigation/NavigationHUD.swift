import SwiftUI

struct NavigationHUD: View {
    @Environment(AppEnvironment.self) private var app
    @State private var showReport = false

    private var nav: NavigationSession { app.navigation }

    var body: some View {
        VStack(spacing: 8) {
            if nav.phase == .prefetching {
                prefetchCard
            } else {
                cueCard
                controlRow
            }
        }
    }

    private var prefetchCard: some View {
        VStack(spacing: 10) {
            Text("PREPARING OFFLINE TILES")
                .font(.dirtUI(10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.7))
            ProgressView(value: app.offline.progress)
                .tint(DirtTheme.orange)
            HStack {
                Text("\(Int(app.offline.progress * 100))%")
                    .font(.dirtMono(12, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Skip") { app.planner.skipPrefetch() }
                    .font(.dirtUI(11, weight: .bold))
                    .foregroundStyle(DirtTheme.orange)
            }
        }
        .padding(14)
        .background(DirtTheme.chrome.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DirtTheme.chromeBorder, lineWidth: 1))
    }

    private var cueCard: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: nav.offRoute ? "exclamationmark.triangle.fill" : "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(nav.offRoute ? DirtTheme.pavedMix : DirtTheme.orange)
                Text(nav.currentCue)
                    .font(.dirtUI(15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                if let meters = nav.currentCueMeters {
                    Text(formatDistance(meters))
                        .font(.dirtMono(15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            HStack {
                Text(formatDistance(nav.remainingMeters) + " to go")
                    .font(.dirtMono(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let eta = nav.etaSeconds {
                    Text("~" + formatDuration(eta))
                        .font(.dirtMono(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(14)
        .background(DirtTheme.chrome.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DirtTheme.chromeBorder, lineWidth: 1))
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            Button("Report") { showReport = true }
                .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))
            Button("End navigation") { app.planner.endNavigation() }
                .buttonStyle(DirtCTAStyle(fill: DirtTheme.navGreen))
        }
        .confirmationDialog("Report a condition", isPresented: $showReport, titleVisibility: .visible) {
            ForEach(["Access closed", "Seasonal gate", "Flooded", "Blocked", "Unsafe", "Other"], id: \.self) { category in
                Button(category) {
                    app.planner.toast = "Report noted on this device (shared reports come with a later build)."
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return "\(minutes / 60) h \(minutes % 60) min"
        }
        return "\(max(minutes, 1)) min"
    }
}
