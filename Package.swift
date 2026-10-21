// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Holgura",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Holgura", targets: ["Holgura"])
    ],
    targets: [
        .target(name: "HolguraCore", path: "Sources/HolguraCore"),
        .executableTarget(name: "Holgura", dependencies: ["HolguraCore"], path: "Sources/Holgura"),
        .testTarget(name: "HolguraCoreTests", dependencies: ["HolguraCore"], path: "Tests/HolguraCoreTests"),
    ]
)
