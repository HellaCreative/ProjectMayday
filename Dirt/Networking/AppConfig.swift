import CoreLocation
import Foundation

/// DIRT iOS endpoints.
/// Road fabric: Cloudflare R2 `dirt-packs` (`graph.v2.bin`) for PACKS download
/// and on-device routing. Live `/api/route` is the default while online if that
/// pack isn’t on the phone. Map tiles are OSM Shortbread. Accounts are Supabase.
enum AppConfig {
    static let baseURL = URL(string: "https://dirt-mayday.vercel.app")!
    static let routeURL = URL(string: "https://dirt-mayday.vercel.app/api/route")!

    /// Public Supabase project (anon key is meant for clients).
    static let supabaseURL = URL(string: "https://iiiguqknqxoumlmppzfw.supabase.co")!
    static let supabasePublishableKey = "sb_publishable_a8B8bxCCrXIP_4uwVxjU2g_3_95g8KM"

    static var mapStyleURL: URL {
        MapStyleCatalog.bundledStyleURL(resource: "shortbread-style")
            ?? Bundle.main.url(forResource: "shortbread-style", withExtension: "json")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Active visual basemap (display only). Routing uses packs on-device and live `/api/route` online.
    static var activeMapStyleURL: URL { MapStyleCatalog.styleURL() }

    /// Versioned graph.v2 packs. Same R2 objects live `/api/route` loads —
    /// download vs cellular is delivery, not a second fabric.
    /// Cloudflare R2 (`dirt-packs` bucket, public r2.dev URL).
    static let packCDNBaseURL = URL(string: "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev")!
    static var packManifestURL: URL { packCDNBaseURL.appendingPathComponent("manifest.json") }

    static func packFileURL(version: String, regionId: String, fileName: String) -> URL {
        _ = version
        return packCDNBaseURL
            .appendingPathComponent(regionId)
            .appendingPathComponent(fileName)
    }

    /// OSM Overpass for viewport camp / lodging / liquor pins. Fuel is pack-only.
    static let overpassURL = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Absolute last-resort map center only when GPS has never delivered a fix
    /// (no province bias — Nova Scotia must not flash at launch).
    static let overviewCenter = CLLocationCoordinate2D(latitude: 39.5, longitude: -98.0)
    static let overviewZoom = 3.5
    /// First-fix framing once location is known (wider than nav detail).
    static let userLaunchZoom = 12.5
}
