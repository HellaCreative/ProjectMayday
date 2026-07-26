import CoreLocation
import Foundation

/// Production backend endpoints. The iOS app talks to the same Vercel + Supabase
/// stack as the web POC — there is no staging environment.
enum AppConfig {
    static let baseURL = URL(string: "https://dirt-mayday.vercel.app")!
    static let routeURL = URL(string: "https://dirt-mayday.vercel.app/api/route")!
    static let supabaseConfigURL = URL(string: "https://dirt-mayday.vercel.app/api/supabase-config")!
    /// Bundled Shortbread style with absolute sprite URLs. The remote production
    /// style uses a root-relative sprite path (`/app/data/...`) which MapLibre
    /// Native resolves as an unsupported URL and can trip offline-pack crashes.
    static var mapStyleURL: URL {
        Bundle.main.url(forResource: "shortbread-style", withExtension: "json")
            ?? URL(string: "https://dirt-mayday.vercel.app/app/data/shortbread-style.json")!
    }

    /// Active visual basemap (display only). Routing data remains OSM via `/api/route`.
    static var activeMapStyleURL: URL { MapStyleCatalog.styleURL() }

    /// Web POC idle camera: NS overview.
    static let overviewCenter = CLLocationCoordinate2D(latitude: 45.1, longitude: -63.0)
    static let overviewZoom = 7.25
}
