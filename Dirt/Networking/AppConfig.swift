import CoreLocation
import Foundation

/// Production backend endpoints. The iOS app talks to the same Vercel + Supabase
/// stack as the web POC — there is no staging environment.
enum AppConfig {
    static let baseURL = URL(string: "https://dirt-mayday.vercel.app")!
    static let routeURL = URL(string: "https://dirt-mayday.vercel.app/api/route")!
    static let supabaseConfigURL = URL(string: "https://dirt-mayday.vercel.app/api/supabase-config")!
    static let mapStyleURL = URL(string: "https://dirt-mayday.vercel.app/app/data/shortbread-style.json")!

    /// Web POC idle camera: NS overview.
    static let overviewCenter = CLLocationCoordinate2D(latitude: 45.1, longitude: -63.0)
    static let overviewZoom = 7.25
}
