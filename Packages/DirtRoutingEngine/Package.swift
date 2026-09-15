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
                // DIRT Dev builds packages incrementally, one file at a time, where the
                // search loop's generic and protocol calls are never specialized: routes
                // ran 2.5-4.7x slower than a Release build. Whole-module optimization
                // restores Release speed. `-num-threads` keeps one object and index file
                // per source, which debug builds' index-while-building requires.
                .unsafeFlags(["-O", "-wmo", "-num-threads", "4", "-cross-module-optimization"])
            ]
        ),
        .executableTarget(name: "RoutingProbe", dependencies: ["DirtRoutingEngine"]),
        .testTarget(name: "DirtRoutingEngineTests", dependencies: ["DirtRoutingEngine"],
                    resources: [.copy("Fixtures")])
    ]
)
