import Foundation
import Observation
import Supabase

/// Supabase Swift SDK for Apple sign-in, profiles, and groups.
/// Publishable key is the public anon key. Sessions live in Keychain.
@Observable
final class SupabaseService {
    private(set) var client: SupabaseClient?
    private(set) var userID: String?
    private(set) var email: String?
    private(set) var displayName: String = ""
    private(set) var bootstrapError: String?

    var isSignedIn: Bool { userID != nil }

    /// Signed in but has not chosen a screen name yet — routes to the screen
    /// name setup step before the map loads.
    var needsDisplayName: Bool {
        isSignedIn && displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func bootstrap() async {
        guard client == nil else { return }
        let client = SupabaseClient(
            supabaseURL: AppConfig.supabaseURL,
            supabaseKey: AppConfig.supabasePublishableKey,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
        self.client = client
        if let session = try? await client.auth.session, !session.isExpired {
            apply(session: session)
        }
        Task {
            for await change in client.auth.authStateChanges {
                if let session = change.session, session.isExpired {
                    continue
                }
                apply(session: change.session)
            }
        }
    }

    private func apply(session: Session?) {
        guard let session else {
            userID = nil
            email = nil
            displayName = ""
            return
        }
        userID = session.user.id.uuidString.lowercased()
        email = session.user.email
        if case let .string(name)? = session.user.userMetadata["display_name"] {
            displayName = name
        }
    }

    // MARK: - Auth (email OTP, unused on iOS UI)

    func sendEmailCode(email: String, displayName: String) async throws {
        guard let client else { throw SupabaseServiceError.notReady }
        try await client.auth.signInWithOTP(
            email: email,
            shouldCreateUser: true,
            data: ["display_name": .string(displayName)]
        )
    }

    func verifyEmailCode(email: String, code: String) async throws {
        guard let client else { throw SupabaseServiceError.notReady }
        try await client.auth.verifyOTP(email: email, token: code, type: .email)
    }

    // MARK: - Sign in with Apple

    /// Exchanges an Apple identity token for a Supabase session.
    /// Requires the Apple provider to be enabled in the Supabase dashboard
    /// (Authentication → Providers → Apple) with `com.mayday.dirt` as an
    /// allowed client ID. `rawNonce` is the un-hashed nonce; Apple was given
    /// its SHA-256, and Supabase verifies the raw value against the token.
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws {
        guard let client else { throw SupabaseServiceError.notReady }
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
        )
        apply(session: session)

        // Apple only returns the name on the very first authorization — capture
        // it as a starting screen name if the account has none yet.
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let fullName {
            let candidate = PersonNameComponentsFormatter.localizedString(from: fullName, style: .default)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                try? await updateDisplayName(candidate)
            }
        }
    }

    func signOut() async throws {
        guard let client else { throw SupabaseServiceError.notReady }
        try await client.auth.signOut()
    }

    /// Permanently deletes the signed-in DIRT account through a server-owned,
    /// fail-closed transaction. The RPC must remove the auth user and all
    /// associated DIRT rows atomically; a client-side series of deletes would
    /// risk reporting success after only a partial deletion.
    func deleteAccount() async throws {
        guard let client, userID != nil else { throw SupabaseServiceError.notReady }
        do {
            try await client.rpc("delete_own_account").execute()
        } catch {
            throw SupabaseServiceError.accountDeletionFailed
        }

        // Supabase removes the local session before attempting the logout
        // request. The auth user no longer exists, so a 401/404 is expected and
        // ignored by the SDK; explicitly clear our observable state as well.
        try? await client.auth.signOut(scope: .local)
        apply(session: nil)
    }

    func updateDisplayName(_ name: String) async throws {
        guard let client, let userID else { throw SupabaseServiceError.notReady }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        try await client.auth.update(user: UserAttributes(data: ["display_name": .string(trimmed)]))
        struct ProfileUpsert: Encodable {
            let id: String
            let display_name: String
            let updated_at: String
        }
        try await client.from("profiles")
            .upsert(
                ProfileUpsert(id: userID, display_name: trimmed, updated_at: ISO8601DateFormatter().string(from: .now)),
                onConflict: "id"
            )
            .execute()
        displayName = trimmed
    }
}

enum SupabaseServiceError: LocalizedError {
    case notReady
    case accountDeletionFailed

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The DIRT account service is still connecting. Try again in a moment."
        case .accountDeletionFailed:
            return "DIRT could not confirm whether account deletion completed. Live group sharing was stopped for safety. Reopen DIRT to check your sign-in state, then try again or contact support."
        }
    }
}
