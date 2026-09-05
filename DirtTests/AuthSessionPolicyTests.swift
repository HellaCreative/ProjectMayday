import Testing
@testable import Dirt

struct AuthSessionPolicyTests {
    @Test func currentSessionKeepsAuthenticatedState() {
        #expect(SupabaseSessionPolicy.accepts(isExpired: false))
    }

    @Test func expiredSessionClearsAuthenticatedState() {
        #expect(!SupabaseSessionPolicy.accepts(isExpired: true))
    }
}
