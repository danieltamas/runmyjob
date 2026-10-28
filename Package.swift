// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RMJ",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RMJCore", targets: ["RMJCore"]),
        .executable(name: "RMJ", targets: ["RMJ"]),
        .executable(name: "RMJCLI", targets: ["RMJCLI"]),
    ],
    targets: [
        // Everything testable without a UI: routing, the run engine, the store. Never imports SwiftUI or AppKit.
        .target(name: "RMJCore"),
        .executableTarget(name: "RMJ", dependencies: ["RMJCore"]),
        // Installed as `rmj`. Named RMJCLI because `rmj` collides with `RMJ` on a case-insensitive
        // disk; scripts/bundle.sh renames the binary.
        .executableTarget(name: "RMJCLI", dependencies: ["RMJCore"]),
        .testTarget(name: "RMJCoreTests", dependencies: ["RMJCore"]),
        // Layout tests: the real views drawn offscreen (`@testable import RMJ`).
        .testTarget(name: "RMJTests", dependencies: ["RMJ", "RMJCore"]),
    ]
)
