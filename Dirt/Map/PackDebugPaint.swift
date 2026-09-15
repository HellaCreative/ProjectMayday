import SwiftUI
import UIKit

/// Phase E3 — debug paint keys for graph overlay (no routing effect).
enum DebugGraphPaintMode: String, CaseIterable, Sendable {
    case access
    case surfaceFamily
    case roadTier

    var title: String {
        switch self {
        case .access: return "Access"
        case .surfaceFamily: return "Surface"
        case .roadTier: return "Road class"
        }
    }
}

enum PackDebugPaint {
    struct LegendItem: Sendable {
        let key: String
        let label: String
        let color: UIColor
        let dashed: Bool
    }

    /// Attribute key written onto debug polylines for the active paint mode.
    static func attributeKey(for mode: DebugGraphPaintMode) -> String {
        switch mode {
        case .access: return "accessClass"
        case .surfaceFamily: return "surfaceFamily"
        case .roadTier: return "roadTier"
        }
    }

    nonisolated static func surfaceFamilyKey(_ family: SurfaceFamily?) -> String {
        (family ?? .unknown).rawValue
    }

    static func legend(for mode: DebugGraphPaintMode) -> [LegendItem] {
        switch mode {
        case .access:
            return [
                .init(key: "motorized_permissive", label: "permissive", color: UIColor(red: 0.18, green: 0.72, blue: 0.32, alpha: 1), dashed: false),
                .init(key: "motorized_verified", label: "verified", color: UIColor(red: 0.12, green: 0.55, blue: 0.28, alpha: 1), dashed: false),
                .init(key: "motorized_unknown", label: "unknown / Allow", color: UIColor(red: 0.95, green: 0.72, blue: 0.12, alpha: 1), dashed: false),
                .init(key: "motorized_restricted", label: "restricted", color: UIColor(red: 0.95, green: 0.48, blue: 0.12, alpha: 1), dashed: true),
                .init(key: "motorized_excluded", label: "excluded", color: UIColor(red: 0.86, green: 0.16, blue: 0.18, alpha: 1), dashed: true),
                .init(key: "atv", label: "ATV designated", color: UIColor(red: 0.72, green: 0.20, blue: 0.92, alpha: 1), dashed: true)
            ]
        case .surfaceFamily:
            return [
                .init(key: "paved", label: "paved", color: UIColor(DirtTheme.routePaved), dashed: false),
                .init(key: "gravel", label: "gravel", color: UIColor(DirtTheme.routeGravel), dashed: false),
                .init(key: "loose", label: "loose / technical", color: UIColor(DirtTheme.routeLoose), dashed: false),
                .init(key: "unknown", label: "unknown surface", color: UIColor(DirtTheme.routeUnknown), dashed: true)
            ]
        case .roadTier:
            return [
                .init(key: "motorway", label: "motorway", color: UIColor(red: 0.90, green: 0.12, blue: 0.18, alpha: 1), dashed: false),
                .init(key: "trunk", label: "trunk", color: UIColor(red: 0.95, green: 0.35, blue: 0.12, alpha: 1), dashed: false),
                .init(key: "arterial", label: "arterial (connector)", color: UIColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1), dashed: false),
                .init(key: "collector", label: "collector (Clean backbone)", color: UIColor(red: 0.15, green: 0.72, blue: 0.38, alpha: 1), dashed: false),
                .init(key: "local_paved", label: "local paved", color: UIColor(red: 0.35, green: 0.82, blue: 0.55, alpha: 1), dashed: false),
                .init(key: "destination", label: "residential / living", color: UIColor(red: 0.95, green: 0.82, blue: 0.20, alpha: 1), dashed: false),
                .init(key: "service", label: "service", color: UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1), dashed: false),
                .init(key: "adventure", label: "track / ATV path", color: UIColor(red: 0.72, green: 0.20, blue: 0.92, alpha: 1), dashed: true),
                .init(key: "unknown", label: "unknown class", color: UIColor(red: 0.45, green: 0.45, blue: 0.48, alpha: 1), dashed: true)
            ]
        }
    }
}
