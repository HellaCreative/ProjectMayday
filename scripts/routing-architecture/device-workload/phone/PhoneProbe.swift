import UIKit
import CoreLocation
import CryptoKit
import os
import Darwin

private let mib = 1_048_576.0
private var uptime: Double { ProcessInfo.processInfo.systemUptime }
private var isSimulator: Bool {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}

private func memory() -> [String: Any] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    var usage = rusage()
    let cpuRC = getrusage(RUSAGE_SELF, &usage)
    var row: [String: Any] = ["uptime": uptime, "memoryReadSucceeded": rc == KERN_SUCCESS,
                              "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
    if rc == KERN_SUCCESS {
        row["physicalFootprintMiB"] = Double(info.phys_footprint) / mib
        row["residentMiB"] = Double(info.resident_size) / mib
    }
    if !isSimulator { row["availableDirtyMemoryMiB"] = Double(os_proc_available_memory()) / mib }
    if cpuRC == 0 {
        row["processCPUSeconds"] = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    return row
}

private final class Recorder: @unchecked Sendable {
    let url: URL
    private let file: FileHandle
    private let lock = NSLock()
    init(_ url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ProbeError("Cannot create evidence file") }
        file = try FileHandle(forWritingTo: url)
    }
    func write(_ row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
        lock.lock(); defer { lock.unlock() }
        try file.write(contentsOf: data)
    }
    deinit { try? file.close() }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Instrumentation runs independently of the UI. These are conservative experiment
// triggers, not measured device limits or hard allocation/deadline guarantees.
private final class Monitor: @unchecked Sendable {
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dirt.probe.monitor", qos: .userInitiated))
    init(control: ProbeControl, recorder: Recorder) {
        let start = uptime
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            let row = memory()
            do { try recorder.write(["stage": "sample", "metrics": row]) }
            catch { control.stop("evidence_write_failed") }
            if row["memoryReadSucceeded"] as? Bool != true { control.stop("memory_metrics_unavailable") }
            if (row["physicalFootprintMiB"] as? Double ?? .infinity) >= 512 { control.stop("memory_budget") }
            if !isSimulator && (row["availableDirtyMemoryMiB"] as? Double ?? 0) < 384 { control.stop("memory_headroom") }
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { control.stop("thermal_pressure") }
            if uptime - start >= 90 { control.stop("session_time_budget") }
        }
        timer.resume()
    }
    deinit { timer.cancel() }
}

@MainActor
private final class ProbeViewController: UIViewController {
    private let status = UILabel()
    private let retained = UILabel()
    private let run = UIButton(type: .system)
    private let stop = UIButton(type: .system)
    private let export = UIButton(type: .system)
    private var control: ProbeControl?
    private var recorder: Recorder?
    private var timer: Timer?
    private var lastTick = uptime
    private var latestURL: URL?
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "DIRT Phone Lab"
        view.backgroundColor = .systemBackground
        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 20
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        func label(_ text: String, style: UIFont.TextStyle, secondary: Bool = false) -> UILabel {
            let value = UILabel(); value.text = text; value.numberOfLines = 0
            value.font = .preferredFont(forTextStyle: style); value.adjustsFontForContentSizeCategory = true
            value.textColor = secondary ? .secondaryLabel : .label
            return value
        }
        let heading = label("Regional planning test", style: .title1)
        heading.accessibilityTraits.insert(.header)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(label("Six Nova Scotia road checks: Clean, Dirt, Balanced, cancellation and recovery. Fuel is not included.", style: .body))
        stack.addArrangedSubview(label("Up to 90 seconds. Stops when time, memory or heat checks trigger. Keep this screen open. Results stay on this device; no server requests.", style: .subheadline, secondary: true))
        if isSimulator { stack.addArrangedSubview(label("Simulator • functional checks only", style: .headline)) }
        for value in [status, retained] {
            value.numberOfLines = 0; value.font = .preferredFont(forTextStyle: .body)
            value.adjustsFontForContentSizeCategory = true
        }
        status.text = "Ready. Tap Run Regional Test to begin."
        retained.text = FileManager.default.fileExists(atPath: documents.appendingPathComponent("last-completed-candidate.json").path)
            ? "Previous candidate retained on this device. Independent road audit required."
            : "No completed candidate yet. Results require an independent road audit."
        stack.addArrangedSubview(status)
        func button(_ button: UIButton, _ title: String, _ selector: Selector, filled: Bool) {
            var config = filled ? UIButton.Configuration.filled() : .bordered()
            config.title = title; config.cornerStyle = .large; config.buttonSize = .large
            button.configuration = config; button.addTarget(self, action: selector, for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            stack.addArrangedSubview(button)
        }
        button(run, "Run Regional Test", #selector(begin), filled: true)
        button(stop, "Stop Test", #selector(cancel), filled: false)
        button(export, "Export Results", #selector(share), filled: false)
        stop.isEnabled = false; export.isEnabled = false
        stack.addArrangedSubview(retained)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pressure), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        UIDevice.current.isBatteryMonitoringEnabled = true
        var autoStart = CommandLine.arguments.contains("--run-authorized-regional-suite")
        #if targetEnvironment(simulator)
        autoStart = autoStart || CommandLine.arguments.contains("--test-autostart")
        #endif
        if autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.begin() }
        }
    }
    @objc private func cancel() { control?.stop("user_cancelled"); status.text = "Stopping. Waiting for the current calculation to return…"; stop.isEnabled = false }
    @objc private func background() { control?.stop("backgrounded") }
    @objc private func pressure() { control?.stop("memory_warning") }
    @objc private func share() {
        guard let latestURL, control == nil else { return }
        let sheet = UIActivityViewController(activityItems: [latestURL], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = export
        present(sheet, animated: true)
    }
    @objc private func begin() {
        guard control == nil else { return }
        let sessionBegan = uptime
        let control = ProbeControl()
        do {
            let url = documents.appendingPathComponent("phone-probe-\(UUID().uuidString).jsonl")
            let recorder = try Recorder(url)
            self.control = control; self.recorder = recorder; latestURL = url
            run.isEnabled = false; stop.isEnabled = true; export.isEnabled = false
            status.text = "Preparing Nova Scotia road data…"
            var system = utsname(); uname(&system)
            let model = withUnsafePointer(to: &system.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
            let manifest = try Data(contentsOf: Bundle.main.url(forResource: "probe-manifest", withExtension: "json")!)
            try recorder.write(["stage": "session", "id": url.lastPathComponent, "simulator": isSimulator,
                "uptimeStart": sessionBegan, "dateUTC": ISO8601DateFormatter().string(from: Date()),
                "hardwareIdentifier": model, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "batteryLevelStart": UIDevice.current.batteryLevel, "batteryStateStart": UIDevice.current.batteryState.rawValue,
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "manifest": try JSONSerialization.jsonObject(with: manifest),
                "limits": ["sampleMillis": 100, "physicalFootprintMiB": 512, "minimumAvailableMiB": 384,
                           "preflightAvailableMiB": 1024, "requestSeconds": 20, "sessionSeconds": 90],
                "scope": "Private road-only harness; no fuel or phone-capacity qualification. Limits are experimental cooperative stop triggers, not hard caps."])
            lastTick = uptime
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = uptime
                    do { try recorder.write(["stage": "ui_heartbeat", "intervalSeconds": now - self.lastTick]) }
                    catch { control.stop("evidence_write_failed") }
                    self.lastTick = now
                }
            }
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("--test-memory-warning") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    try? recorder.write(["stage": "injected_event", "event": "memory_warning", "simulatorOnly": true])
                    NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                }
            }
            #endif
            let output = documents
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Self.perform(control: control, recorder: recorder, output: output) { text in
                    DispatchQueue.main.async { self.status.text = text }
                }
                DispatchQueue.main.async {
                    self.timer?.invalidate(); self.timer = nil
                    var finalOutcome = outcome
                    do { try recorder.write(["stage": "finished", "outcome": outcome,
                        "endToEndSeconds": uptime - sessionBegan,
                        "batteryLevelEnd": UIDevice.current.batteryLevel, "batteryStateEnd": UIDevice.current.batteryState.rawValue,
                        "metrics": memory()]) }
                    catch { finalOutcome = "evidence_write_failed" }
                    self.control = nil; self.recorder = nil
                    self.run.isEnabled = true; self.stop.isEnabled = false; self.export.isEnabled = true
                    self.status.text = finalOutcome == "complete" ? "Test finished. Export the results for review." : "Calculation incomplete: \(finalOutcome.replacingOccurrences(of: "_", with: " ")). Export results or retry when ready."
                    self.retained.text = FileManager.default.fileExists(atPath: output.appendingPathComponent("last-completed-candidate.json").path)
                        ? "Last completed candidate retained. Independent road audit required."
                        : "No completed candidate. No route or fuel conclusion has been made."
                    UIAccessibility.post(notification: .announcement, argument: self.status.text)
                }
            }
        } catch {
            self.control = nil; self.recorder = nil
            run.isEnabled = true; stop.isEnabled = false
            status.text = "Could not start: \(error). Retry after checking available storage."
        }
    }

    nonisolated private static func perform(control: ProbeControl, recorder: Recorder, output: URL,
                                            progress: @escaping @Sendable (String) -> Void) -> String {
        let monitor = Monitor(control: control, recorder: recorder)
        defer { withExtendedLifetime(monitor) {} }
        do {
            if !isSimulator && Double(os_proc_available_memory()) / mib < 1024 { control.stop("preflight_memory_headroom") }
            if let stop = control.outcome { return stop.reason }
            let t = uptime
            let root = Bundle.main.bundleURL
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("probe-manifest.json"))) as! [String: Any]
            let hashes = manifest["resourceHashes"] as! [String: String]
            func verified(_ name: String) throws -> Data {
                let data = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hashes[name] else { throw ProbeError("Resource identity mismatch: \(name)") }
                return data
            }
            let graphData = try verified("graph.v4.bin"), geometryData = try verified("geometry.v1.bin")
            _ = try verified("UrbanSettlements.json")
            let queries = try JSONSerialization.jsonObject(with: verified("queries.json")) as! [[String: Any]]
            guard control.outcome == nil else { return control.outcome!.reason }
            _ = try GraphV4Pack(data: graphData, geometry: geometryData)
            let pack = try GraphV2Pack(data: graphData); pack.regionId = "ns"
            pack.geometry = try GeometryV1Pack(data: geometryData)
            try recorder.write(["stage": "loaded", "decodeAndIdentitySeconds": uptime - t,
                "nodes": pack.nodeCount, "edges": pack.undirectedEdgeCount,
                "graphBytes": graphData.count, "geometryBytes": geometryData.count, "metrics": memory()])
            for (index, query) in queries.enumerated() {
                if let stop = control.outcome { return stop.reason }
                guard Set(query.keys).isSubset(of: ["case", "start", "end", "profile", "allowUnknown", "cancelAfterMillis", "searchBudgetMillis"]),
                      let start = query["start"] as? [Double], start.count == 2,
                      let end = query["end"] as? [Double], end.count == 2,
                      let name = query["profile"] as? String,
                      let profile = RouteProfile(rawValue: name == "clean" ? "cleanest" : name),
                      let unknown = query["allowUnknown"] as? Bool else { throw ProbeError("Unsupported road fixture contract") }
                progress("Check \(index + 1) of \(queries.count) • \(query["case"] as? String ?? name)")
                let began = uptime, request = ProbeControl()
                let deadline = began + min(20, (query["searchBudgetMillis"] as? Double ?? 20_000) / 1000)
                let cancelAt = began + (query["cancelAfterMillis"] as? Double ?? .infinity) / 1000
                @Sendable func stopped() -> Bool {
                    if uptime >= cancelAt { request.stop("scheduled_cancel") }
                    if uptime >= deadline { request.stop("time_budget") }
                    return control.outcome != nil || request.outcome != nil
                }
                var row: [String: Any] = ["query": query, "stage": "query", "metricsBefore": memory()]
                var router = OnDeviceRouter(pack: pack); router.executionCancelled = { stopped() }
                let result = router.routeDetailed(from: CLLocationCoordinate2D(latitude: start[1], longitude: start[0]),
                    to: CLLocationCoordinate2D(latitude: end[1], longitude: end[0]), profile: profile,
                    allowUnknown: unknown, sessionSeed: 1)
                row["searchSeconds"] = uptime - began
                row["metricsAfter"] = memory()
                if stopped() {
                    let stop = control.outcome ?? request.outcome!
                    row["state"] = "incomplete"; row["reason"] = stop.reason
                    row["stopObservedToReturnSeconds"] = uptime - stop.at
                    if cancelAt.isFinite { row["scheduledCancelToReturnSeconds"] = uptime - cancelAt }
                    if query["searchBudgetMillis"] != nil { row["deadlineOvershootSeconds"] = max(0, uptime - deadline) }
                } else {
                    switch result {
                    case .failure(let reason): row["state"] = "native_failure"; row["reason"] = String(describing: reason)
                    case .success(let route):
                        if route.searchMeta.timedOut {
                            row["state"] = "incomplete"; row["reason"] = "native_search_budget"
                        } else {
                            row["state"] = "found"; row["distanceMeters"] = route.distanceMeters
                            row["knownDirtPercent"] = route.reportedDirtPercent
                            row["legs"] = route.legs.map { leg -> [String: Any] in
                                ["edgeId": leg.edgeId, "edgeIndex": leg.edgeIndex as Any? ?? NSNull(),
                                 "fromNode": leg.fromNode as Any? ?? NSNull(), "toNode": leg.toNode as Any? ?? NSNull(),
                                 "meters": leg.distanceMeters, "surface": leg.surfaceName,
                                 "coordinates": leg.coordinates.map { [$0.longitude, $0.latitude] }]
                            }
                        }
                    }
                }
                // Serial worker + disabled Run prevent overlap. Recheck after geometry
                // assembly so interrupted candidates never replace the last completed one.
                if row["state"] as? String == "found" {
                    let data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
                    let canPublish = !stopped()
                    let published = try canPublish && control.publishIfRunning {
                        try data.write(to: output.appendingPathComponent("last-completed-candidate.json"), options: .atomic)
                    }
                    if !published {
                        row.removeValue(forKey: "legs"); row["state"] = "incomplete"
                        row["reason"] = (control.outcome ?? request.outcome)?.reason ?? "publication_cancelled"
                    }
                }
                try recorder.write(row)
            }
            return control.outcome?.reason ?? "complete"
        } catch { return "error: \(error)" }
    }
}

@main
@MainActor
final class PhoneProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: ProbeViewController())
        window.makeKeyAndVisible(); self.window = window
        return true
    }
}
