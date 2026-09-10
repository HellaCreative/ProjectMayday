import AuthenticationServices
import Testing
@testable import Dirt

struct AppleCredentialPolicyTests {
    @Test func authorizedOrTransferredCredentialsKeepSession() {
        for state in [ASAuthorizationAppleIDProvider.CredentialState.authorized, .transferred] {
            #expect(!AppleCredentialPolicy.shouldSignOut(state: state, checkedToken: "old", currentToken: "old"))
        }
    }
    @Test func confirmedRevocationSignsOutCurrentSession() {
        for state in [ASAuthorizationAppleIDProvider.CredentialState.revoked, .notFound] {
            #expect(AppleCredentialPolicy.shouldSignOut(state: state, checkedToken: "old", currentToken: "old"))
        }
    }
    @Test func staleResultCannotSignOutNewOrClearedSession() {
        for token in ["new", nil] as [String?] {
            #expect(!AppleCredentialPolicy.shouldSignOut(state: .revoked, checkedToken: "old", currentToken: token))
        }
    }
}
