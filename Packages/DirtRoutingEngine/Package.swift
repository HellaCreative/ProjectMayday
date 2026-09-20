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
                // Keep the phone/Play engine optimized across its source files,
                // just like the Release host probe. Xcode's Debug default is
                // per-file compilation even when -O is explicitly enabled.
                // Threaded emission preserves SwiftPM's per-file object/index
                // outputs; cap compiler parallelism for the shared build host.
                .unsafeFlags(["-O", "-whole-module-optimization", "-num-threads", "2",
                              "-cross-module-optimization"])
            ]
        ),
        .executableTarget(name: "RoutingProbe", dependencies: ["DirtRoutingEngine"]),
        .testTarget(name: "DirtRoutingEngineTests", dependencies: ["DirtRoutingEngine"],
                    resources: [.copy("Fixtures")])
    ]
)
