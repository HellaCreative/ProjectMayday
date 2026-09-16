import CoreLocation
import SwiftUI

/// Opt-in post-ride upload of ordered network edge ids (no raw GPS).
struct ContributeTrackSheet: View {
    @Environment(AppEnvironment.self) private var app
    let candidate: RideContributionCandidate
    let onDone: () -> Void

    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            Capsule()
                .fill(DirtTheme.ink.opacity(0.18))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, DirtSpace.inner)

            Text("Contribute this ride?")
                .font(DirtType.rowTitle)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.ink)

            Text("Share the roads you just rode so we can harden packs each month. No GPS trail is stored.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.danger)
            }

            if app.supabase.isSignedIn {
                Button {
                    Task { await contribute() }
                } label: {
                    Text(busy ? "Uploading…" : "Contribute")
                        .font(DirtType.cta)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(DirtTheme.onOrange)
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                        .background(DirtTheme.orange, in: RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
                }
                .disabled(busy)
                .accessibilityLabel("Contribute this ride")
            } else {
                AppleSignInButton { result in
                    handleSignIn(result)
                }
                .disabled(busy)
                .opacity(busy ? 0.65 : 1)
            }

            Button("Not now") {
                TrackContributePrefs.hasBeenAsked = true
                onDone()
            }
            .font(DirtType.rowTitle)
            .foregroundStyle(DirtTheme.muted)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min)

            Button {
                TrackContributePrefs.isEnabled = true
                TrackContributePrefs.hasBeenAsked = true
            } label: {
                Text("Remember: ask after rides")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.orange)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(DirtSpace.row)
        .dirtGroupingSurface(radius: DirtRadius.card)
        .padding(.horizontal, DirtSpace.row)
        .padding(.bottom, DirtSpace.row)
        .background(DirtTheme.sheetMaterial)
    }

    private func handleSignIn(_ result: Result<AppleCredential, Error>) {
        switch result {
        case let .success(credential):
            guard !busy else { return }
            busy = true
            errorMessage = nil
            Task {
                defer { busy = false }
                do {
                    try await app.supabase.signInWithApple(
                        idToken: credential.idToken,
                        rawNonce: credential.rawNonce,
                        fullName: credential.fullName
                    )
                } catch {
                    errorMessage = AppleSignInFailure.message(from: error)
                }
            }
        case let .failure(error):
            errorMessage = AppleSignInFailure.message(from: error)
        }
    }

    private func contribute() async {
        busy = true
        errorMessage = nil
        defer { busy = false }

        var coords: [CLLocationCoordinate2D] = []
        if let c = app.location.currentCoordinate {
            coords.append(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        }
        let regionCodes = GraphPackStore.regionIds(containingAny: coords)

        let ok = await app.rideIntelligence.contributeTrack(
            edgeIds: candidate.edgeIds,
            distanceMeters: candidate.distanceMeters,
            regionCodes: regionCodes,
            packVersion: app.graphPacks.lastManifestVersion,
            startedAt: candidate.startedAt
        )
        TrackContributePrefs.hasBeenAsked = true
        if ok {
            TrackContributePrefs.isEnabled = true
            app.planner.toast = "Thanks — ride contributed"
            onDone()
        } else {
            errorMessage = "Couldn’t upload. Check sign-in and try again."
        }
    }
}
