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
                .unsafeFlags(["-O", "-cross-module-optimization"])
            ]
        ),
        .executableTarget(name: "RoutingProbe", dependencies: ["DirtRoutingEngine"]),
        .testTarget(name: "DirtRoutingEngineTests", dependencies: ["DirtRoutingEngine"],
                    resources: [.copy("Fixtures")])
    ]
)
