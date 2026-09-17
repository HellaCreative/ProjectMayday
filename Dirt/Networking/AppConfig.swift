import CoreLocation
import Foundation

/// DIRT iOS endpoints.
/// Road fabric: Cloudflare R2 `dirt-packs` (`graph.v2.bin`) for PACKS download
/// and on-device navigation recovery. Live `/api/route` is always the planning
/// source of truth while online, regardless of installed packs. Map tiles use
/// the Shortbread schema through Dirt's health-gated edge service. Accounts are Supabase.
enum DirtBackendEnvironment: String, Sendable {
    case development
    case production
}

enum AppConfig {
    /// Must match the deployed route and fuel-chain service. A missing or stale
    /// value is rejected so device evidence cannot silently mix releases.
    nonisolated static let routingServiceContract = "dirt-routing.r0.v1"
    /// Candidate manifest for Dirt-hosted Shortbread tiles. The app keeps the
    /// public OSM Shortbread origin until this manifest and its R2 sample pass.
    nonisolated static let shortbreadManifestURL = URL(
        string: "https://dirt-shortbread-tiles.dirt-shortbread-edge.workers.dev/shortbread/v1/manifest.json"
    )!

    /// Build-time backend selection. This is deliberately not a runtime toggle:
    /// a development binary cannot be switched onto real rider data.
    #if DIRT_DEVELOPMENT
    nonisolated static let backendEnvironment: DirtBackendEnvironment = .development
    private nonisolated static let configuredRoutingBaseURL = URL(
        string: "https://pack-fabric.vercel.app"
    )!
    private nonisolated static let expectedRoutingHost = "pack-fabric.vercel.app"
    private nonisolated static let configuredSupabaseURL = URL(
        string: "https://xoufaiypnrgukzmdwicz.supabase.co"
    )!
    private nonisolated static let expectedSupabaseHost = "xoufaiypnrgukzmdwicz.supabase.co"

    /// Publishable client keys are safe to embed. Privileged Supabase keys are
    /// never accepted by this configuration surface.
    nonisolated static let supabasePublishableKey = "sb_publishable_nap5DKdcWCHOpbHc6gXEwQ_YU6MI7WY"
    #else
    nonisolated static let backendEnvironment: DirtBackendEnvironment = .production
    private nonisolated static let configuredRoutingBaseURL = URL(
        string: "https://dirt-mayday.vercel.app"
    )!
    private nonisolated static let expectedRoutingHost = "dirt-mayday.vercel.app"
    private nonisolated static let configuredSupabaseURL = URL(
        string: "https://iiiguqknqxoumlmppzfw.supabase.co"
    )!
    private nonisolated static let expectedSupabaseHost = "iiiguqknqxoumlmppzfw.supabase.co"
    nonisolated static let supabasePublishableKey = "sb_publishable_a8B8bxCCrXIP_4uwVxjU2g_3_95g8KM"
    #endif

    nonisolated static let supabaseURL: URL = {
        precondition(
            validatesSupabaseIsolation(url: configuredSupabaseURL),
            "DIRT build environment and Supabase project do not match."
        )
        return configuredSupabaseURL
    }()

    nonisolated static let baseURL: URL = {
        precondition(
            validatesRoutingIsolation(url: configuredRoutingBaseURL),
            "DIRT build environment and routing service do not match."
        )
        return configuredRoutingBaseURL
    }()

    nonisolated static var routeURL: URL { baseURL.appendingPathComponent("api/route") }
    /// Candidate-aware packed fuel for live planning. The server resolves the
    /// same regional source override as `/api/route`.
    nonisolated static var liveFuelURL: URL { baseURL.appendingPathComponent("api/fuel") }
    /// One bounded graph pass per committed fuel waypoint. This returns an
    /// ordered pump chain; final ride legs still come from `/api/route`.
    nonisolated static var liveFuelChainURL: URL { baseURL.appendingPathComponent("api/fuel-chain") }
    /// Campground, lodging, and liquor viewport POIs from checksum-verified,
    /// DIRT-owned regional sidecars. The running app never contacts OSM.
    nonisolated static var livePOIURL: URL { baseURL.appendingPathComponent("api/poi") }

    nonisolated static func validatesSupabaseIsolation(url: URL) -> Bool {
        url.host == expectedSupabaseHost
    }

    nonisolated static func validatesRoutingIsolation(url: URL) -> Bool {
        url.scheme == "https" && url.host == expectedRoutingHost
    }

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
    nonisolated static let packCDNBaseURL = URL(string: "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev")!
    nonisolated static var packManifestURL: URL {
        #if DIRT_DEVELOPMENT
        v4CandidateBaseURL.appendingPathComponent("manifest.json")
        #else
        v4ProductionBaseURL.appendingPathComponent("manifest.json")
        #endif
    }
    nonisolated static var riderServicesManifestURL: URL {
        #if DIRT_DEVELOPMENT
        v4CandidateBaseURL.appendingPathComponent("rider-services/manifest.json")
        #else
        v4ProductionBaseURL.appendingPathComponent("rider-services/manifest.json")
        #endif
    }

    nonisolated static func packFileURL(version: String, regionId: String, fileName: String) -> URL {
        _ = version
        #if DIRT_DEVELOPMENT
        return v4CandidateBaseURL
            .appendingPathComponent(regionId.lowercased())
            .appendingPathComponent(fileName)
        #else
        return v4ProductionBaseURL
            .appendingPathComponent(regionId.lowercased())
            .appendingPathComponent(fileName)
        #endif
    }

    /// Immutable production bytes verified against the accepted national pack audit.
    nonisolated static var v4ProductionBaseURL: URL {
        packCDNBaseURL.appendingPathComponent("v4/releases/fabric-v4-20260909-02")
    }

    #if DIRT_DEVELOPMENT
    /// Full national DEV candidate with ON/QC/CA/NL splits. Production keeps
    /// its approved release bytes. Never pin a partial-only catalog again.
    nonisolated static let v4ConnectionRevision = v4CandidateReleaseId
    nonisolated static var v4ConnectionBaseURL: URL {
        v4CandidateBaseURL
    }
    nonisolated static let v4CandidateReleaseId = "fabric-v4-20260917-02"
    nonisolated static var v4CandidateBaseURL: URL {
        packCDNBaseURL.appendingPathComponent("v4/candidates/\(v4CandidateReleaseId)")
    }
    #endif

    /// Absolute last-resort map center only when GPS has never delivered a fix
    /// (no province bias — Nova Scotia must not flash at launch).
    static let overviewCenter = CLLocationCoordinate2D(latitude: 39.5, longitude: -98.0)
    static let overviewZoom = 3.5
    /// First-fix framing once location is known (wider than nav detail).
    static let userLaunchZoom = 12.5
}
