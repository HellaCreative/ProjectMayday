import Foundation
import Observation
import Supabase

/// Wraps the Supabase Swift SDK against the same project the web POC uses.
/// The client is created from the public `/api/supabase-config` endpoint so no
/// key ships in the binary beyond what production already exposes. Sessions
/// are persisted by the SDK's default secure (Keychain) storage.
@Observable
final class SupabaseService {
    private(set) var client: SupabaseClient?
    private(set) var userID: String?
    private(set) var email: String?
    private(set) var displayName: String = ""
    private(set) var bootstrapError: String?

    var isSignedIn: Bool { userID != nil }

    func bootstrap() async {
        guard client == nil else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: AppConfig.supabaseConfigURL)
            struct RemoteConfig: Decodable {
                let url: String
                let publishableKey: String
            }
            let config = try JSONDecoder().decode(RemoteConfig.self, from: data)
            guard let url = URL(string: config.url), !config.publishableKey.isEmpty else {
                bootstrapError = "Supabase is not configured for this deployment."
                return
            }
            let client = SupabaseClient(supabaseURL: url, supabaseKey: config.publishableKey)
            self.client = client
            if let session = try? await client.auth.session {
                apply(session: session)
            }
            Task {
                for await change in client.auth.authStateChanges {
                    apply(session: change.session)
                }
            }
        } catch {
            bootstrapError = "Could not reach the DIRT account service."
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

    // MARK: - Auth (email OTP, matching web)

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

    func signOut() async throws {
        guard let client else { throw SupabaseServiceError.notReady }
        try await client.auth.signOut()
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

    var errorDescription: String? {
        "The DIRT account service is still connecting. Try again in a moment."
    }
}
