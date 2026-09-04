import Foundation
import Network
import os
import SQLite3

/// Localhost HTTP server that serves Mapbox Vector Tiles from an `.mbtiles`
/// SQLite database (tippecanoe output). Flips TMS `tile_row` → XYZ `y` for
/// MapLibre URL templates.
///
/// Not MainActor-isolated — NWListener callbacks run on `queue`.
final class MBTilesVectorProxy: @unchecked Sendable {
    private let mbtilesURL: URL
    private var db: OpaquePointer?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dirt.bc.osm.mbtiles-proxy")
    private let portLock = OSAllocatedUnfairLock(initialState: UInt16(0))
    private let dbLock = OSAllocatedUnfairLock(initialState: false)

    init(mbtilesURL: URL) {
        self.mbtilesURL = mbtilesURL
    }

    var port: UInt16 {
        portLock.withLock { $0 }
    }

    var isRunning: Bool {
        queue.sync { listener != nil && port > 0 }
    }

    /// `http://127.0.0.1:<port>/{z}/{x}/{y}.mvt`
    var tileURLTemplate: String? {
        let p = port
        guard p > 0 else { return nil }
        return "http://127.0.0.1:\(p)/{z}/{x}/{y}.mvt"
    }

    func start() async throws {
        if isRunning { return }
        try openDatabase()

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
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
                        gate.resumeFailure(NSError(domain: "DirtBCOSM", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "BC OSM mbtiles proxy failed to bind a port."
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
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
            dbLock.withLock { $0 = false }
        }
    }

    // MARK: - SQLite

    private func openDatabase() throws {
        if dbLock.withLock({ $0 }) { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(mbtilesURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "DirtBCOSM", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not open \(mbtilesURL.lastPathComponent) (sqlite \(rc))."
            ])
        }
        db = handle
        dbLock.withLock { $0 = true }
    }

    /// Look up tippecanoe tile. MapLibre asks XYZ; mbtiles stores TMS row.
    private func tileData(z: Int, x: Int, yXYZ: Int) -> Data? {
        let yTMS = (1 << z) - 1 - yXYZ
        guard let db else { return nil }
        let sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(z))
        sqlite3_bind_int(stmt, 2, Int32(x))
        sqlite3_bind_int(stmt, 3, Int32(yTMS))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, 0))
        guard length > 0 else { return nil }
        return Data(bytes: blob, count: length)
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
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        if path == "/" || path == "/tiles.json" {
            let body = tileJSON().data(using: .utf8) ?? Data()
            send(status: 200, body: body, on: connection, contentType: "application/json")
            return
        }

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

        if let data = tileData(z: zVal, x: x, yXYZ: y), !data.isEmpty {
            // tippecanoe stores gzip-compressed MVT by default (magic 1F8B).
            // Label it so MapLibre's HTTP stack inflates; do not strip the gzip.
            let isGzip = data.count >= 2
                && data[data.startIndex] == 0x1f
                && data[data.startIndex + 1] == 0x8b
            send(
                status: 200,
                body: data,
                on: connection,
                contentType: "application/vnd.mapbox-vector-tile",
                contentEncoding: isGzip ? "gzip" : nil
            )
        } else {
            send(status: 204, body: Data(), on: connection)
        }
    }

    private func tileJSON() -> String {
        let p = port
        let template = "http://127.0.0.1:\(p)/{z}/{x}/{y}.mvt"
        // Geofabrik BC extract bounds from tippecanoe metadata.
        // Source-layer id "dirt_roads" must match tippecanoe `-l dirt_roads`
        // in scripts/build-bc-tiles.sh (and MapLibre `sourceLayerIdentifier`).
        return """
        {
          "tilejson": "2.2.0",
          "name": "DIRT BC OSM hierarchy",
          "tiles": ["\(template)"],
          "minzoom": 4,
          "maxzoom": 14,
          "bounds": [-137.137313, 48.309518, -114.037104, 60.120707],
          "vector_layers": [{
            "id": "dirt_roads",
            "fields": {
              "highway": "String",
              "surface": "String",
              "tracktype": "String",
              "name": "String",
              "data_confidence": "String"
            }
          }]
        }
        """
    }

    private func send(
        status: Int,
        body: Data,
        on connection: NWConnection,
        contentType: String = "application/octet-stream",
        contentEncoding: String? = nil
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        if let contentEncoding {
            header += "Content-Encoding: \(contentEncoding)\r\n"
        }
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// One-shot resume helper (mirrors OfflineTileProxy).
    private final class ResumeGate: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Error>

        nonisolated init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        nonisolated func resumeSuccess() {
            let first = lock.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { continuation.resume() }
        }

        nonisolated func resumeFailure(_ error: Error) {
            let first = lock.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { continuation.resume(throwing: error) }
        }
    }
}
