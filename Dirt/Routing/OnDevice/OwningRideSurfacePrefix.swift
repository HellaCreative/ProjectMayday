import Foundation

/// Immutable owning-rider-leg accounting. A missing contribution is unknown,
/// not zero; older saved routes cannot manufacture exact totals from percents.
nonisolated struct OwningRideSurfacePrefix: Codable, Hashable, Sendable {
    let riderLegID: UUID
    let contribution: NativeRideSurfaceContext?
    init(riderLegID: UUID, contribution: NativeRideSurfaceContext? = .zero) {
        self.riderLegID = riderLegID; self.contribution = contribution
    }
    func appending(_ local: NativeRideSurfaceContext?, initialApproach: Bool = false) -> Self {
        if initialApproach { return Self(riderLegID: riderLegID) }
        return Self(riderLegID: riderLegID, contribution: contribution.flatMap { prefix in
            local.flatMap { prefix.adding($0) }
        })
    }
    func beginning(_ owner: UUID) -> Self {
        owner == riderLegID ? self : Self(riderLegID: owner)
    }
}
