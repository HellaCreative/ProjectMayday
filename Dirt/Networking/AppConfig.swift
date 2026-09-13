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
        packCDNBaseURL.appendingPathComponent("manifest.json")
        #endif
    }
    nonisolated static var riderServicesManifestURL: URL {
        packCDNBaseURL.appendingPathComponent("rider-services/v1/manifest.json")
    }

    nonisolated static func packFileURL(version: String, regionId: String, fileName: String) -> URL {
        _ = version
        #if DIRT_DEVELOPMENT
        if Self.nsV4CandidateFileNames.contains(fileName) {
            return v4CandidateBaseURL
                .appendingPathComponent(regionId.lowercased())
                .appendingPathComponent(fileName)
        }
        #endif
        return packCDNBaseURL
            .appendingPathComponent(regionId)
            .appendingPathComponent(fileName)
    }

    #if DIRT_DEVELOPMENT
    /// DEV-only accepted physical-routing pack pair. Never used by production.
    /// This is the pack identity used by the September 8 physical qualification,
    /// rather than the later unqualified hybrid candidate.
    nonisolated static let v4CandidateReleaseId = "fabric-v4-20260908-02"
    nonisolated static var v4CandidateBaseURL: URL {
        packCDNBaseURL
            .appendingPathComponent("v4")
            .appendingPathComponent("candidates")
            .appendingPathComponent(v4CandidateReleaseId)
    }
    nonisolated static let nsV4CandidateFileNames: Set<String> = [
        "graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "pack-manifest.v2.json",
        "cross-pack-seams.v2.json"
    ]
    nonisolated static let nsV4GraphBytes = 15_012_189
    nonisolated static let nsV4GraphSHA256 =
        "91a10b490918531de330b9bcd2209de1708a4beb50625bfab4969e59e23d551d"
    nonisolated static let nsV4GeometryBytes = 23_954_228
    nonisolated static let nsV4GeometrySHA256 =
        "b4ee898537829666f3825ff50e3bff2a73f9b423a558ffde814a1abdd75649ac"
    nonisolated static let nsV4FuelBytes = 143_951
    nonisolated static let nsV4FuelSHA256 =
        "62b9baf355740619f48f64938bfdfee4d447ed8ba4d2a4d65d3d2ecb513ee549"
    #endif

    /// Absolute last-resort map center only when GPS has never delivered a fix
    /// (no province bias — Nova Scotia must not flash at launch).
    static let overviewCenter = CLLocationCoordinate2D(latitude: 39.5, longitude: -98.0)
    static let overviewZoom = 3.5
    /// First-fix framing once location is known (wider than nav detail).
    static let userLaunchZoom = 12.5
}
