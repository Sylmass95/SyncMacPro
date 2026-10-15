// swift-tools-version: 5.9
// Outil d'essai des mises à jour automatiques (scripts/try-update.sh) : paquet à part, pour que la construction de
// l'app n'ait qu'un exécutable lié à Sparkle (deux copies de Sparkle.framework font échouer la construction universelle).
import PackageDescription

let package = Package(
    name: "update-probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SyncMacPro", path: "../..")],
    targets: [
        .executableTarget(name: "update-probe", dependencies: [.product(name: "SyncMacProUI", package: "SyncMacPro")]),
    ]
)
