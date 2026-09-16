import Testing
import UIKit
@testable import Dirt

struct RiderServiceColorTests {
    @Test func layersGlyphTokensMatchMapDots() {
        let expected: [(String, UInt32)] = [
            ("fuel", DirtTheme.poiFuelHex),
            ("campground", DirtTheme.poiCampgroundHex),
            ("lodging", DirtTheme.poiLodgingHex),
            ("liquor", DirtTheme.poiLiquorHex)
        ]
        #expect(DirtTheme.poiFuelHex == 0xE8730C)
        #expect(DirtTheme.poiCampgroundHex == 0x2F9E44)
        #expect(DirtTheme.poiLodgingHex == 0x8A5A2B)
        #expect(DirtTheme.poiLiquorHex == 0x8E44C9)
        #expect(DirtTheme.poiFuelHex != 0xFF8000)

        for (id, hex) in expected {
            let map = MapLibreMapView.POILayer.categories.first { $0.id == id }?.color
            let theme = DirtTheme.poiUIColor(for: id)
            #expect(map != nil)
            #expect(colorsMatch(map, UIColor(dirtHex: hex)))
            #expect(colorsMatch(theme, UIColor(dirtHex: hex)))
            #expect(colorsMatch(map, theme))
            #expect(MapLibreMapView.POILayer.systemSymbolName(for: id).hasSuffix(".fill"))
        }
    }

    @Test func unknownCategoryDoesNotUseBrandOrange() {
        let fallback = DirtTheme.poiUIColor(for: "unknown")
        #expect(!colorsMatch(fallback, UIColor(dirtHex: DirtTheme.poiFuelHex)))
        #expect(!colorsMatch(fallback, UIColor(dirtHex: 0xFF8000)))
    }
}

private func colorsMatch(_ lhs: UIColor?, _ rhs: UIColor, accuracy: CGFloat = 0.002) -> Bool {
    guard let lhs else { return false }
    var lR: CGFloat = 0, lG: CGFloat = 0, lB: CGFloat = 0, lA: CGFloat = 0
    var rR: CGFloat = 0, rG: CGFloat = 0, rB: CGFloat = 0, rA: CGFloat = 0
    guard lhs.getRed(&lR, green: &lG, blue: &lB, alpha: &lA),
          rhs.getRed(&rR, green: &rG, blue: &rB, alpha: &rA) else { return false }
    return abs(lR - rR) <= accuracy
        && abs(lG - rG) <= accuracy
        && abs(lB - rB) <= accuracy
        && abs(lA - rA) <= accuracy
}
