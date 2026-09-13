import AuthenticationServices

/// Apply only a definitive result for the exact session that requested it.
enum AppleCredentialPolicy {
    nonisolated static func shouldSignOut(
        state: ASAuthorizationAppleIDProvider.CredentialState,
        checkedToken: String,
        currentToken: String?
    ) -> Bool {
        guard currentToken == checkedToken else { return false }
        return state == .revoked || state == .notFound
    }
}
