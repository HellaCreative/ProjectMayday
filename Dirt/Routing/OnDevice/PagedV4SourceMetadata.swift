import Foundation

nonisolated enum PagedV4SourceMetadata {
    static func sourceEpoch(_ legal: PagedV4Core.LegalQuery) throws -> String {
        try legal.validateSource()
        // Observed immutable NS/NB/ON provenance lengths:103229/127305/1146734.
        // Decode only the epoch property from unchanged provenance; no invented
        // default. This is bounded metadata parsing, not an all-road allocation.
        let count = try legal.sectionLength(.provenance)
        guard count > 0,count <= 2*1024*1024 else { throw PagedV4Core.Failure.metadataLimit }
        var data = Data();data.reserveCapacity(count)
        for offset in stride(from: 0,to: count,by: 65_536) {
            let lease = try legal.sectionChunk(.provenance,offset: offset,count: min(65_536,count-offset))
            lease.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        struct Epoch: Decodable { let sourceEpoch: String? }
        guard let epoch = try JSONDecoder().decode(Epoch.self,from: data).sourceEpoch,!epoch.isEmpty else {
            throw NativeRoutingContinuationError.unavailableSourceEpoch
        }
        try legal.validateSource()
        return epoch
    }
}
