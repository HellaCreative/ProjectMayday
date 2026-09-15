import Testing
import DirtRoutingEngine
@testable import Dirt

struct PackDebugPaintTests {
    @Test func surfaceAndRoadKeysMatchEnums() {
        #expect(PackDebugPaint.surfaceFamilyKey(.gravel) == "gravel")
        #expect(ProfilePolicy.tier("secondary") == "collector")
        #expect(ProfilePolicy.tier("tertiary") == "local_paved")
    }

    @Test func legendsCoverPaintModes() {
        #expect(PackDebugPaint.legend(for: .surfaceFamily).contains { $0.key == "gravel" })
        #expect(PackDebugPaint.legend(for: .roadTier).contains { $0.key == "collector" })
        #expect(PackDebugPaint.legend(for: .access).contains { $0.key == "atv" })
    }
}
