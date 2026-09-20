// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DirtRoutingEngine",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "DirtRoutingEngine", targets: ["DirtRoutingEngine"]),
               .executable(name: "dirt-routing-probe", targets: ["RoutingProbe"])],
    targets: [
        .target(
            name: "DirtRoutingEngine",
            swiftSettings: [
                // Preserve Xcode's compilation/output model. Forcing WMO here
                // omits per-file App Intents metadata on a fresh Play build.
                // Hot generic helpers expose their bodies for specialization.
                .unsafeFlags(["-O", "-cross-module-optimization"])
            ]
        ),
        .executableTarget(name: "RoutingProbe", dependencies: ["DirtRoutingEngine"]),
        .testTarget(name: "DirtRoutingEngineTests", dependencies: ["DirtRoutingEngine"],
                    resources: [.copy("Fixtures")])
    ]
)
