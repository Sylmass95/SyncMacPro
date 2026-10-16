import XCTest
@testable import SyncKit

/// 1.6.2 : après une mise à jour (signature ad hoc nouvelle), macOS redemande l'accès aux dossiers protégés ; rsync
/// attendait la réponse sans rien dire (2 h 13 lors de l'essai réel). Une sonde courte le détecte avant le moteur.
final class AccessProbeTests: IntegrationTestCase {
    func runner(probe: @escaping @Sendable (String) -> (String, [String]), timeout: TimeInterval) throws -> TaskRunner {
        var configuration = RunnerConfiguration(rsyncPath: try rsyncPath(), workDirectory: sandbox.appendingPathComponent("w"))
        configuration.accessProbe = probe
        configuration.accessProbeTimeout = timeout
        return TaskRunner(configuration: configuration)
    }

    func testAFolderThatDoesNotAnswerStopsTheRunWithAClearMessage() async throws {
        let source = try folder("Bureau")
        try Data("x".utf8).write(to: URL(fileURLWithPath: source).appendingPathComponent("a.txt"))
        let destination = sandbox.appendingPathComponent("copie").path
        let runner = try runner(probe: { _ in ("/bin/sleep", ["30"]) }, timeout: 0.5)
        let started = Date()
        let result = try await runner.run(task(source, destination))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "pas d'attente sans fin")
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.retryable)
        let message = try XCTUnwrap(result.summary.message)
        XCTAssertTrue(message.contains("« Bureau »"), message)
        XCTAssertTrue(message.contains("autoris"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination + "/a.txt"), "le moteur n'a pas été lancé")
    }

    func testAReadableFolderIsCopiedAsUsual() async throws {
        let source = try folder("Bureau")
        try Data("x".utf8).write(to: URL(fileURLWithPath: source).appendingPathComponent("a.txt"))
        let destination = sandbox.appendingPathComponent("copie").path
        let runner = try runner(probe: RunnerConfiguration.defaultAccessProbe, timeout: 15)
        let result = try await runner.run(task(source, destination))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination + "/a.txt"))
    }

    func testTheProbedFolderOfANewDestinationIsItsFirstExistingParent() throws {
        let parent = try folder("Disque")
        XCTAssertEqual(TaskRunner.probedFolder(parent + "/Sauvegardes/Photos"), VolumeLookup.canonical(parent))
        XCTAssertEqual(TaskRunner.probedFolder(parent), VolumeLookup.canonical(parent))
    }
}
