import Foundation

/// Request-scoped work limits. This carries an existing caller deadline into
/// native worker tasks; it does not define route costs or a new search budget.
nonisolated enum RoutingWorkContext {
    @TaskLocal static var deadline: Double?
    @TaskLocal static var measurement: RoutingMeasurement?
    /// Qualification toggle: calculation/matching semantics remain identical.
    @TaskLocal static var usePackGeometryEnvelope = true

    static var stopReason: String? {
        if Task.isCancelled { return "cancelled" }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
            return "fuelWindowTimeCap"
        }
        return nil
    }

    static func check() throws {
        try Task.checkCancellation()
        if stopReason != nil {
            throw RoutingError.fuelUnknown("Fuel planning reached its time budget. A fuel gap has not been proved.")
        }
    }

    static func limitedDeadline(milliseconds: Int?) -> Double? {
        guard let milliseconds else { return deadline }
        let requested = ProcessInfo.processInfo.systemUptime + Double(max(0, milliseconds)) / 1000
        return min(deadline ?? requested, requested)
    }

    static func detachedSearch<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        let deadline = deadline
        let measurement = measurement
        let envelope = usePackGeometryEnvelope
        let worker = Task.detached(priority: .userInitiated) {
            Self.$deadline.withValue(deadline) {
                Self.$measurement.withValue(measurement) {
                    Self.$usePackGeometryEnvelope.withValue(envelope) { operation() }
                }
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    static func detachedThrowingSearch<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let deadline = deadline
        let measurement = measurement
        let envelope = usePackGeometryEnvelope
        let worker = Task.detached(priority: .userInitiated) {
            try Self.$deadline.withValue(deadline) {
                try Self.$measurement.withValue(measurement) {
                    try Self.$usePackGeometryEnvelope.withValue(envelope) { try operation() }
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

}
