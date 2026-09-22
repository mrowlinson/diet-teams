// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Absolute -L for the prebuilt Rust staticlib (built by scripts/build-rust.sh).
// Derived from this manifest's location so no env var is needed.
let rustLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // swift/
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("rust/ostmac-core/target/release")
    .standardizedFileURL.path

let rustLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(rustLibDir)", "-lostmac_core"]),
    .linkedFramework("Security"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("SystemConfiguration"),
]

let package = Package(
    name: "OstMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OstMac", targets: ["OstMac"]),
        .executable(name: "ostmac-mcp", targets: ["ostmac-mcp"]),
    ],
    targets: [
        .target(name: "COstMac", publicHeadersPath: "include"),
        .target(name: "OstMacCore", dependencies: ["COstMac"]),
        .target(name: "OstMacChatList", dependencies: ["OstMacCore"]),
        .target(name: "OstMacMCP", dependencies: ["OstMacCore"]),
        .executableTarget(
            name: "OstMac",
            dependencies: ["OstMacCore", "OstMacChatList", "COstMac"],
            linkerSettings: rustLink
        ),
        .executableTarget(
            name: "ostmac-mcp",
            dependencies: ["OstMacMCP", "OstMacCore", "COstMac"],
            linkerSettings: rustLink
        ),
        .testTarget(
            name: "OstMacCoreTests",
            dependencies: ["OstMacCore", "OstMacChatList", "COstMac"],
            linkerSettings: rustLink
        ),
        .testTarget(
            name: "OstMacMCPTests",
            dependencies: ["OstMacMCP", "OstMacCore", "COstMac"],
            linkerSettings: rustLink
        ),
    ]
)
