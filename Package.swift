// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncMacPro",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .executable(name: "synckit-cli", targets: ["synckit-cli"]),
        .executable(name: "syncmacpro-ctl", targets: ["syncmacpro-ctl"]),
        .executable(name: "syncmacpro-agent", targets: ["syncmacpro-agent"]),
        .executable(name: "SyncMacPro", targets: ["SyncMacPro"]),
    ],
    targets: [
        .target(name: "SyncKit"),
        .executableTarget(name: "synckit-cli", dependencies: ["SyncKit"]),
        .executableTarget(name: "syncmacpro-ctl", dependencies: ["SyncKit"]),
        .executableTarget(name: "syncmacpro-agent", dependencies: ["SyncKit"]),
        .target(name: "SyncMacProUI", dependencies: ["SyncKit"], resources: [.process("Resources")]),
        .executableTarget(name: "SyncMacPro", dependencies: ["SyncMacProUI"]),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SyncMacProUITests", dependencies: ["SyncMacProUI", "SyncKit"], resources: [.copy("Fixtures")]),
    ]
)
