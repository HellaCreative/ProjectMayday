import Foundation

extension OnDeviceRouter.SearchMeta {
    /// Preserve the approved fallback wording in every native conversion path.
    /// These flags describe the actual selected search pass, not a percentage
    /// heuristic. Existing warnings keep their order and distinct messages.
    func routeWarnings(merging existing: [RouteWarning]? = nil) -> [RouteWarning]? {
        var result = existing ?? []
        var generated = limitedSearchWarning.map { [$0] } ?? []
        if urbanCoreFallbackUsed {
            generated.append(RouteWarning(code: "urban_core_fallback",
                message: "No route could reach the destination while keeping every urban core as a wall. This Clean route uses an urban crossing only as a last resort."))
        }
        if cleanUnpavedFallbackUsed {
            generated.append(RouteWarning(code: "clean_unpaved_fallback",
                message: "No fully paved route could reach the destination while respecting the current routing walls. Clean used tagged unpaved road only as a last resort."))
        }
        if settlementFallbackUsed {
            generated.append(RouteWarning(code: "settlement_fallback",
                message: "This route could not avoid every mapped town without losing its routing objective. Town travel remains strongly penalized and is used only where the alternatives are worse."))
        }
        for warning in generated where !result.contains(where: { $0.code == warning.code && $0.message == warning.message }) {
            result.append(warning)
        }
        return result.isEmpty ? nil : result
    }
}
