import Foundation

/// Throttles transfer notifications; no task or timer survives the download.
nonisolated final class RoutingPackDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0
    private let report: @Sendable (Int64) -> Void

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let emit = now - lastReport >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite
        if emit { lastReport = now }
        lock.unlock()
        if emit { report(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
