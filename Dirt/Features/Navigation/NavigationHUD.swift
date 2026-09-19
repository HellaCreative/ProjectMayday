import CoreLocation
import SwiftUI

/// Navigation chrome — Figma `Navigation — Turn Left - Junction` (node 50:5240):
/// - Top: `DIRT.` · turn cue (+ distance) · dark speed
/// - Bottom: full-bleed portrait ride panel

// MARK: - Cue card (top center)

struct NavCueCard: View {
    @Environment(AppEnvironment.self) private var app
    /// When set, the card is clipped to the landscape top band so it lines up with speed and brand.
    var bandHeight: CGFloat? = nil

    private var nav: NavigationSession { app.navigation }

    var body: some View {
        VStack(alignment: .leading, spacing: nav.missTurnActive ? 10 : 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: arrowSymbol)
                    .font(.system(size: cueIconSize, weight: .bold))
                    .foregroundStyle(nav.offRoute ? DirtTheme.danger : DirtTheme.orange)
                    .frame(width: 44, height: 44)
                    .scaleEffect(cueBand == .now && !nav.offRoute ? 1.08 : 1)
