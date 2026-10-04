// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Current",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Current", targets: ["Traffic"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CNetwork"),
        .target(name: "TrafficCore", dependencies: ["CSQLite", "CNetwork"]),
        .executableTarget(name: "Traffic", dependencies: ["TrafficCore"]),
        .testTarget(name: "TrafficCoreTests", dependencies: ["TrafficCore"]),
        .testTarget(name: "TrafficAppTests", dependencies: ["Traffic", "TrafficCore"])
    ]
)
