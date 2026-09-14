import Foundation

/// Exact directed-code/endpoint scope law. Caller must first prove the actual
/// CSR direction and obtain its verified code; this never fabricates an arc.
nonisolated enum NativeV4AccessPolicy {
    static func allowed(code: UInt8, edge ei: Int, startEdge startEi: Int, endEdge endEi: Int,
        allowUnknown: Bool,startEndpointKind: String? = nil,endEndpointKind: String? = nil,
        customerStartEdges: Set<Int> = [],customerEndEdges: Set<Int> = []) -> Bool {
        if code == 0 { return true }
        if code == 1 { return allowUnknown }
        if code == 2 || code == 5 { return false }
        if code == 3 {
            return (ei == startEi && startEndpointKind != "customers")
                || (ei == endEi && endEndpointKind != "customers")
        }
        if code == 4 {
            return ((ei == startEi || customerStartEdges.contains(ei)) && startEndpointKind == "customers")
                || ((ei == endEi || customerEndEdges.contains(ei)) && endEndpointKind == "customers")
        }
        return false
    }
}
