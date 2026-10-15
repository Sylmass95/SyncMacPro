// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncMacPro",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncKit", targets: ["SyncKit"]),
        // Pour l'outil d'essai des mises à jour (Tools/update-probe), paquet à part.
        .library(name: "SyncMacProUI", targets: ["SyncMacProUI"]),
        .executable(name: "synckit-cli", targets: ["synckit-cli"]),
        .executable(name: "syncmacpro-ctl", targets: ["syncmacpro-ctl"]),
        .executable(name: "syncmacpro-agent", targets: ["syncmacpro-agent"]),
        .executable(name: "SyncMacPro", targets: ["SyncMacPro"]),
    ],
    dependencies: [
        // Mises à jour automatiques (sous-projet 8) ; version épinglée.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "SyncKit"),
        .executableTarget(name: "synckit-cli", dependencies: ["SyncKit"]),
        .executableTarget(name: "syncmacpro-ctl", dependencies: ["SyncKit"]),
        .executableTarget(name: "syncmacpro-agent", dependencies: ["SyncKit"]),
        .target(name: "SyncMacProUI", dependencies: ["SyncKit", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")]),
        .executableTarget(name: "SyncMacPro", dependencies: ["SyncMacProUI"]),
        .testTarget(
            name: "SyncKitTests",
            dependencies: ["SyncKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SyncMacProUITests", dependencies: ["SyncMacProUI", "SyncKit", .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Fixtures")]),
    ]
)
