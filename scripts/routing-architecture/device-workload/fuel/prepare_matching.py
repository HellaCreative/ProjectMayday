"""Asserted, private snapshot patch. Original search costs and projections stay intact."""
from pathlib import Path


def patch(root: Path):
    path = root / 'OnDeviceRouter.swift'
    source = path.read_text()
    def replace(old, new):
        nonlocal source
        assert source.count(old) == 1, old[:100]
        source = source.replace(old, new)

    replace('''        for pump in pumps {
            let ll''', '''        for pump in pumps {
            if executionCancelled() { return [:] }
            let ll''')
    replace('''        var best = Double.infinity
        let snaps = nearestEdgeSnaps(
            to: point, allowUnknown: allowUnknown, profile: profile,
            maxMeters: Self.preferredMatchMeters
        )''', '''        var best = Double.infinity
        let snaps = fuelSnaps(to: point, profile: profile, allowUnknown: allowUnknown)''')
    replace('''        let grid = PackEdgeSpatialIndex.shared.grid(for: pack)
''', '''        guard !executionCancelled(), let grid = PackEdgeSpatialIndex.shared.grid(for: pack, cancelled: executionCancelled) else { return [] }
''')
    replace('''        var checked = Set<Int>()
        for radius in 0...maxRadius {
            for ei in grid.edgeIndices(nearLat: lat, lon: lon, radiusCells: radius) {
''', '''        let candidates: [Int]
        let indexedCandidates = NativeFuelPreparation.indexed
            ? Set(grid.edgeIndices(in: FuelMatchBounds.around(point, meters: maxMeters), cancelled: executionCancelled)) : []
        if NativeFuelPreparation.indexed {
            if NativeFuelPreparation.verify {
                // Project the broad reference area too: every qualifying
                // reference match must survive the geographic filter.
                let reference = (0...maxRadius).flatMap { grid.edgeIndices(nearLat: lat, lon: lon, radiusCells: $0) }
                candidates = Array(Set(reference).union(indexedCandidates)).sorted()
            } else { candidates = indexedCandidates.sorted() }
        } else {
            candidates = (0...maxRadius).flatMap { grid.edgeIndices(nearLat: lat, lon: lon, radiusCells: $0) }
        }
        var checked = Set<Int>(), projectedEdges = 0, projectedSegments = 0, omittedMatches = 0
        defer { NativeFuelPreparation.recordMatch(edges: projectedEdges, segments: projectedSegments, omitted: omittedMatches) }
        for _ in 0..<1 {
            for ei in candidates {
                if executionCancelled() { return [] }
''')
    replace('''                var along = 0.0
                for i in 1..<poly.count {
                    let segA''', '''                projectedEdges += 1
                var along = 0.0
                for i in 1..<poly.count {
                    if executionCancelled() { return [] }
                    projectedSegments += 1
                    let segA''')
    replace('''                    if d <= maxMeters {
                        let candidate = EdgeSnap(''', '''                    if d <= maxMeters {
                        if NativeFuelPreparation.verify, !indexedCandidates.contains(ei) { omittedMatches += 1 }
                        let candidate = EdgeSnap(''')
    replace('''        let ranked = bestByEdge.values.sorted { $0.distanceMeters < $1.distanceMeters }''', '''        let ranked = bestByEdge.values.sorted {
            $0.distanceMeters == $1.distanceMeters ? $0.edgeIndex < $1.edgeIndex : $0.distanceMeters < $1.distanceMeters
        }''')
    replace('''        scored.sort { $0.score < $1.score }''', '''        scored.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.edgeIndex != $1.edgeIndex { return $0.edgeIndex < $1.edgeIndex }
            return $0.forward && !$1.forward
        }''')
    replace('''    private struct EdgeSnap {''', (Path(__file__).parent / 'FuelSnapCache.fragment').read_text() + '\n    private struct EdgeSnap {')
    replace('''            coordinates: [tap, snap.projected],
            distanceMeters: d,''', '''            coordinates: idSuffix == "end" ? [snap.projected, tap] : [tap, snap.projected],
            distanceMeters: d,''')
    start = source.index('/// Degree-cell index of undirected edges by endpoint bbox.')
    assert source[start:].rstrip().endswith('return built\n    }\n}')
    source = source[:start] + (Path(__file__).parent / 'MatchingIndex.fragment').read_text()
    path.write_text(source)
