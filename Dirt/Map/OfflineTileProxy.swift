import Foundation
import Network
import os

/// Tiny localhost HTTP server that serves Shortbread MVT tiles from the
/// nav corridor cache, with network fill-through when a tile is missing.
///
/// Intentionally **not** MainActor-isolated — NWListener callbacks run on
/// `queue`, and the proxy is shared from `@MainActor` tile manager via
/// `nonisolated(unsafe)`.
final class OfflineTileProxy: @unchecked Sendable {
    private let cacheDirectory: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dirt.offline.tile-proxy")
    private let portLock = OSAllocatedUnfairLock(initialState: UInt16(0))

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    var port: UInt16 {
        portLock.withLock { $0 }
    }

    var isRunning: Bool {
        queue.sync { listener != nil && port > 0 }
    }

    /// Starts the localhost tile server without blocking the main thread.
    func start() async throws {
        if isRunning { return }

        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.handle(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let p = listener.port?.rawValue ?? 0
                    self?.portLock.withLock { $0 = p }
                    if p > 0 {
                        gate.resumeSuccess()
                    } else {
                        gate.resumeFailure(NSError(domain: "DirtOffline", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Offline tile proxy failed to bind a port."
                        ]))
                    }
                case .failed(let error):
                    gate.resumeFailure(error)
                default:
                    break
                }
            }
            self.queue.async {
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            portLock.withLock { $0 = 0 }
        }
    }

    func fileURL(for tile: CorridorTilePlanner.Tile) -> URL {
        cacheDirectory
            .appendingPathComponent("\(tile.z)", isDirectory: true)
            .appendingPathComponent("\(tile.x)", isDirectory: true)
            .appendingPathComponent("\(tile.y).mvt")
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: next.subdata(in: next.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                self.respond(to: header, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: next)
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(status: 400, body: Data("bad request".utf8), on: connection)
            return
        }
        let path = String(parts[1])
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count >= 3,
              let yPart = comps.last?.replacingOccurrences(of: ".mvt", with: ""),
              let y = Int(yPart),
              let x = Int(comps[comps.count - 2]),
              let zVal = Int(comps[comps.count - 3])
        else {
            send(status: 404, body: Data(), on: connection)
            return
        }
        let tile = CorridorTilePlanner.Tile(z: zVal, x: x, y: y)
        if let data = try? Data(contentsOf: fileURL(for: tile)), !data.isEmpty {
            send(status: 200, body: data, on: connection, contentType: "application/vnd.mapbox-vector-tile")
            return
        }
        URLSession.shared.dataTask(with: tile.remoteURL) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            guard let data, !data.isEmpty, code == 200 else {
                self.send(status: 404, body: Data(), on: connection)
                return
            }
            try? self.store(data, for: tile)
            self.send(status: 200, body: data, on: connection, contentType: "application/vnd.mapbox-vector-tile")
        }.resume()
    }

    func store(_ data: Data, for tile: CorridorTilePlanner.Tile) throws {
        let url = fileURL(for: tile)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func send(
        status: Int,
        body: Data,
        on connection: NWConnection,
        contentType: String = "text/plain"
    ) {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// One-shot resume helper safe for NWListener state callbacks.
private final class ResumeGate: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    private let continuation: CheckedContinuation<Void, Error>

    nonisolated init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    nonisolated func resumeSuccess() {
        let should = lock.withLock { resumed -> Bool in
            if resumed { return false }
            resumed = true
            return true
        }
        if should { continuation.resume() }
    }

    nonisolated func resumeFailure(_ error: Error) {
        let should = lock.withLock { resumed -> Bool in
            if resumed { return false }
            resumed = true
            return true
        }
        if should { continuation.resume(throwing: error) }
    }
}
