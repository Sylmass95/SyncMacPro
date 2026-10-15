import XCTest
@testable import SyncKit

/// Essai réel du 15/10 : un .psb de 6,5 Go à 0 octet sur Drive (envoi jamais fini) a été copié vide sur le NAS.
final class EmptySourceGuardTests: IntegrationTestCase {
    func testOnlyEmptySourcesOverNonEmptyDestinationsAreProtected() {
        let protected = EmptySourceGuard.protectedPaths(
            sourceEmpty: ["a.psb", "nouveau.txt", "vide-partout.txt"],
            destinationSizes: ["a.psb": 6_488_591_566, "vide-partout.txt": 0]
        )
        XCTAssertEqual(protected, ["a.psb"])
    }

    func testRsyncCopyDoesNotOverwriteWithAnEmptyFile() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/dossier [1]/gros.psb", "")
        try write(destination + "/dossier [1]/gros.psb", "contenu précieux")
        try write(source + "/nouveau-vide.txt", "")
        try write(source + "/normal.txt", "x")
        var copy = task(source, destination)
        copy.options.excludes = []
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read(destination + "/dossier [1]/gros.psb"), "contenu précieux")
        XCTAssertTrue(exists(destination + "/nouveau-vide.txt"), "un fichier vide nouveau est copié")
        XCTAssertEqual(read(destination + "/normal.txt"), "x")
        XCTAssertEqual(result.summary.message, EmptySourceGuard.message(count: 1))
    }

    func testRcloneCopyDoesNotOverwriteWithAnEmptyFile() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/sous/gros*.psb", "")
        try write(destination + "/sous/gros*.psb", "contenu précieux")
        try write(source + "/nouveau-vide.txt", "")
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":local", path: destination))
        copy.options.excludes = []
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read(destination + "/sous/gros*.psb"), "contenu précieux")
        XCTAssertTrue(exists(destination + "/nouveau-vide.txt"))
        XCTAssertEqual(result.summary.message, EmptySourceGuard.message(count: 1))
    }
}
