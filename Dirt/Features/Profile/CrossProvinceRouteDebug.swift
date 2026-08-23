import Foundation

/// On-device mirror of `scripts/debug-cross-province-route.mjs`.
/// Read-only POSTs to production `AppConfig.routeURL`; writes a shareable report.
enum CrossProvinceRouteDebug {
    struct Pin: Sendable {
        var latitude: Double
        var longitude: Double
        var label: String

        var routeLocation: RouteLocation {
            RouteLocation(latitude: latitude, longitude: longitude, label: label)
        }
    }

    struct Outcome: Sendable {
        let reportURL: URL
        let reportText: String
        let passCount: Int
        let failCount: Int
        let interpretation: String
    }

    /// Default pins — keep in sync with `scripts/debug-cross-province-route.mjs`.
    /// `nonisolated` so they can be default arguments under MainActor isolation.
    nonisolated static let pinA = Pin(latitude: 49.0253, longitude: -122.8029, label: "White Rock BC")
    nonisolated static let pinB = Pin(latitude: 49.6956, longitude: -112.8451, label: "outside Lethbridge AB")

    private static let endpoint = AppConfig.routeURL
    /// Runs the full diagnostic suite and writes
    /// `Documents/dirt-cross-province-debug-YYYYMMDD-HHmmss.txt`.
    static func run(
        a: Pin = pinA,
        b: Pin = pinB,
        session: URLSession? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
        let urlSession = session ?? makeSession()
        let bcHop = Pin(latitude: a.latitude, longitude: a.longitude + 0.1, label: "BC hop near A")
        let abHop = Pin(latitude: b.latitude, longitude: b.longitude + 0.1, label: "AB hop near B")

        var lines: [String] = []
        lines.append("DIRT cross-province route debug (iOS Profile)")
        lines.append("Endpoint: \(endpoint.absoluteString)")
        lines.append("Started: \(isoNow())")
        lines.append("A: \(a.latitude),\(a.longitude) (\(a.label))")
        lines.append("B: \(b.latitude),\(b.longitude) (\(b.label))")
        lines.append("BC control B': \(bcHop.latitude),\(bcHop.longitude)")
        lines.append("AB control B': \(abHop.latitude),\(abHop.longitude)")
        lines.append("")

        var results: [AttemptResult] = []

        // 1) Full A→B — dirt + balanced × allow on/off
        for profile in [RouteProfile.dirt, .balanced] {
            for allow in [true, false] {
                progress?("full A→B \(profile.rawValue) allow=\(allow ? "on" : "off")")
                let r = await attempt(
                    label: "full A→B",
                    profile: profile,
                    locations: [a, b],
                    allowUnknown: allow,
                    session: urlSession
                )
                results.append(r)
                lines.append(r.line)
            }
        }

        // 2) Control: BC-only short hop near A
        progress?("control BC-only")
        let bc = await attempt(
            label: "control BC-only",
            profile: .dirt,
            locations: [a, bcHop],
            allowUnknown: true,
            session: urlSession
        )
        results.append(bc)
        lines.append(bc.line)

        // 3) Control: AB-only short hop near B
        progress?("control AB-only")
        let ab = await attempt(
            label: "control AB-only",
            profile: .dirt,
            locations: [b, abHop],
            allowUnknown: true,
            session: urlSession
        )
        results.append(ab)
        lines.append(ab.line)

        // 4) Reverse B→A — dirt + balanced, allow on
        for profile in [RouteProfile.dirt, .balanced] {
            progress?("reverse B→A \(profile.rawValue)")
            let r = await attempt(
                label: "reverse B→A",
                profile: profile,
                locations: [b, a],
                allowUnknown: true,
                session: urlSession
            )
            results.append(r)
            lines.append(r.line)
        }

        let summary = summaryBlock(results)
        lines.append("")
        lines.append(contentsOf: summary.lines)
        lines.append("Finished: \(isoNow())")

        let text = lines.joined(separator: "\n") + "\n"
        let url = try writeReport(text)
        let pass = results.filter(\.ok).count
        let fail = results.count - pass
        return Outcome(
            reportURL: url,
            reportText: text,
            passCount: pass,
            failCount: fail,
            interpretation: summary.interpretation
        )
    }

    // MARK: - Attempt

    private struct AttemptResult: Sendable {
        let label: String
        let profile: String
        let allowUnknown: Bool
        let ok: Bool
        let line: String
    }

    private static func attempt(
        label: String,
        profile: RouteProfile,
        locations: [Pin],
        allowUnknown: Bool,
        session: URLSession
    ) async -> AttemptResult {
        let request = RouteRequest(
            profile: profile,
            locations: locations.map(\.routeLocation),
            allowUnknown: allowUnknown
        )
        let t0 = Date()
        var http: Int?
        var json: [String: Any]?
        var errMsg: String?

        do {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            urlRequest.timeoutInterval = RoutingClient.longHaulTimeout

            let (data, urlResponse) = try await session.data(for: urlRequest)
            http = (urlResponse as? HTTPURLResponse)?.statusCode
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = obj
            } else {
                let snippet = String(data: data.prefix(120), encoding: .utf8)?
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) ?? "<binary>"
                errMsg = truncate(snippet, 60)
            }
        } catch {
            errMsg = truncate(error.localizedDescription, 60)
        }

        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let status = (json?["status"] as? String)
            ?? (errMsg != nil ? "fetch_error" : "no_json")
        let message = truncate(
            (json?["message"] as? String)
                ?? (json?["error"] as? String)
                ?? errMsg
                ?? "-",
            70
        )
        let pts = json.map(geometryPointCount) ?? nil
        let dist = number(json?["distanceMeters"])
        let dirt = dirtPct(json)
        let unk = unknownPct(json)
        let warn = warningsText(json)
        let dbg = debugKeysText(json)

        let ok =
            http == 200
            && (status == "complete" || status == "ok")
            && (pts ?? 0) > 1
            && dist.map { $0 > 0 } == true

        let line =
            "\(ok ? "PASS" : "FAIL") | \(label) | profile=\(profile.rawValue) allow=\(allowUnknown ? "on" : "off") | "
            + "http=\(http.map(String.init) ?? "-") status=\(status) msg=\(message) | "
            + "pts=\(pts.map(String.init) ?? "-") dist=\(fmtKm(dist)) dirt=\(fmtPct(dirt)) unk=\(fmtPct(unk)) | "
            + "warn=\(warn) | dbg=\(dbg) | \(ms)ms"

        return AttemptResult(
            label: label,
            profile: profile.rawValue,
            allowUnknown: allowUnknown,
            ok: ok,
            line: line
        )
    }

    // MARK: - Summary (parity with .mjs)

    private struct Summary {
        let lines: [String]
        let interpretation: String
    }

    private static func summaryBlock(_ results: [AttemptResult]) -> Summary {
        let full = results.filter { $0.label.hasPrefix("full A→B") }
        let reverse = results.filter { $0.label.hasPrefix("reverse B→A") }
        let bc = results.filter { $0.label.hasPrefix("control BC") }
        let ab = results.filter { $0.label.hasPrefix("control AB") }

        func allPass(_ arr: [AttemptResult]) -> Bool { !arr.isEmpty && arr.allSatisfy(\.ok) }
        func anyPass(_ arr: [AttemptResult]) -> Bool { arr.contains(where: \.ok) }
        func allFail(_ arr: [AttemptResult]) -> Bool { !arr.isEmpty && arr.allSatisfy { !$0.ok } }
        func grade(_ arr: [AttemptResult]) -> String {
            if allPass(arr) { return "PASS" }
            if allFail(arr) { return "FAIL" }
            return "MIXED"
        }

        let controlsPass = allPass(bc) && allPass(ab)
        let controlsPartial = (anyPass(bc) || anyPass(ab)) && !(allPass(bc) && allPass(ab))
        let fullFail = allFail(full)
        let fullAnyPass = anyPass(full)

        let interpretation: String
        if controlsPass && fullFail {
            interpretation =
                "LIKELY CHAIN/SEAM BUG: both province controls work, but full cross-province A→B fails."
        } else if !allPass(bc) && allPass(ab) {
            interpretation =
                "LIKELY FABRIC / BC-SIDE ISSUE: BC control failing while AB control works (mid-rebuild or pack gap on BC)."
        } else if allPass(bc) && !allPass(ab) {
            interpretation =
                "LIKELY FABRIC / AB-SIDE ISSUE: AB control failing while BC control works (mid-rebuild or pack gap on AB)."
        } else if !anyPass(bc) && !anyPass(ab) && fullFail {
            interpretation =
                "BROADER OUTAGE / POLICY: both controls and full A→B failing — check API health, packs, or access policy."
        } else if controlsPass && fullAnyPass {
            interpretation =
                "CROSS-PROVINCE OK (or partially OK): controls pass and at least one full A→B succeeds."
        } else if controlsPartial {
            interpretation =
                "MIXED CONTROLS: one province side unreliable — inspect failing control before blaming canada-chain."
        } else {
            interpretation =
                "INCONCLUSIVE: inspect per-line FAIL details (status/message/dbg) above."
        }

        return Summary(lines: [
            "========== SUMMARY ==========",
            "Controls: BC-only \(grade(bc)) | AB-only \(grade(ab))",
            "Full A→B: \(fullAnyPass ? (allPass(full) ? "ALL PASS" : "PARTIAL") : "ALL FAIL") (\(full.filter(\.ok).count)/\(full.count))",
            "Reverse B→A: \(anyPass(reverse) ? (allPass(reverse) ? "ALL PASS" : "PARTIAL") : "ALL FAIL") (\(reverse.filter(\.ok).count)/\(reverse.count))",
            "Interpretation: \(interpretation)",
            "=============================",
        ], interpretation: interpretation)
    }

    // MARK: - File I/O

    private static func writeReport(_ text: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = Self.fileStamp()
        let url = docs.appendingPathComponent("dirt-cross-province-debug-\(stamp).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = RoutingClient.longHaulTimeout
        cfg.timeoutIntervalForResource = RoutingClient.longHaulTimeout
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }

    // MARK: - JSON helpers (parity with .mjs)

    private static func geometryPointCount(_ json: [String: Any]) -> Int? {
        if let g = json["geometry"] as? [Any], !g.isEmpty { return g.count }
        if let g = json["geometry"] as? [String: Any],
           (g["type"] as? String) == "LineString",
           let coords = g["coordinates"] as? [Any] {
            return coords.count
        }
        if let segments = json["segments"] as? [[String: Any]] {
            var n = 0
            for seg in segments {
                if let pts = seg["geometry"] as? [Any] {
                    n += pts.count
                } else if let pts = seg["coords"] as? [Any] {
                    n += pts.count
                }
            }
            return n > 0 ? n : nil
        }
        return nil
    }

    private static func dirtPct(_ json: [String: Any]?) -> Double? {
        guard let json else { return nil }
        if let stats = json["stats"] as? [String: Any], let v = number(stats["dirtPercent"]) { return v }
        return number(json["dirtPercent"])
    }

    private static func unknownPct(_ json: [String: Any]?) -> Double? {
        guard let json else { return nil }
        if let stats = json["stats"] as? [String: Any], let v = number(stats["unknownAccessPercent"]) {
            return v
        }
        return number(json["unknownAccessPercent"])
    }

    private static func warningsText(_ json: [String: Any]?) -> String {
        guard let w = json?["warnings"] as? [Any], !w.isEmpty else { return "-" }
        return w.map { item -> String in
            if let s = item as? String { return s }
            if let d = item as? [String: Any] {
                let code = d["code"] as? String ?? ""
                let msg = d["message"] as? String ?? ""
                return [code, msg].filter { !$0.isEmpty }.joined(separator: ":")
            }
            return String(describing: item)
        }.joined(separator: "|")
    }

    private static func debugKeysText(_ json: [String: Any]?) -> String {
        guard let json else { return "-" }
        var bits: [String] = []
        let interesting = try! NSRegularExpression(
            pattern: "^(debug|chain|seam|pack|region|hop|canada|fabric|router|engine|mode|stage)",
            options: .caseInsensitive
        )

        for (k, v) in json {
            let range = NSRange(k.startIndex..., in: k)
            guard interesting.firstMatch(in: k, options: [], range: range) != nil else { continue }
            bits.append("\(k)=\(jsonValueString(v))")
        }

        if let debug = json["debug"] as? [String: Any] {
            for (k, v) in debug {
                bits.append("debug.\(k)=\(jsonValueString(v))")
            }
        }

        return bits.isEmpty ? "-" : bits.joined(separator: " ")
    }

    private static func jsonValueString(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: v)
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func fmtKm(_ meters: Double?) -> String {
        guard let meters, meters.isFinite else { return "-" }
        return String(format: "%.1fkm", meters / 1000)
    }

    private static func fmtPct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "-" }
        if v == floor(v) { return "\(Int(v))%" }
        return String(format: "%.0f%%", v)
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n - 1)) + "…"
    }
}
