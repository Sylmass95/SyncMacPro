import XCTest
@testable import SyncKit

/// Corrections mineures de la 1.3.0, côté moteurs.
final class Fix140RunnerTests: IntegrationTestCase {
    func testAverageSpeedExcludesPauses() {
        let start = Date(timeIntervalSince1970: 1_000)
        let runner = TaskRunner(configuration: RunnerConfiguration(
            workDirectory: sandbox.appendingPathComponent("w"), now: { Date(timeIntervalSince1970: 1_100) }
        ))
        var snapshot = TransferSnapshot()
        snapshot.activeTime = 10
        snapshot.doneBytes = 100
        let result = runner.result(status: .succeeded, engine: .rsync, snapshot: snapshot, started: start)
        XCTAssertEqual(result.summary.averageSpeed, 10, "100 o en 10 s actives (90 s de pause)")
    }

    func testBackslashIsEscapedOnlyWithWildcards() {
        XCTAssertEqual(EmptySourceGuard.rsyncEscape(#"a\b.txt"#), #"a\b.txt"#)
        XCTAssertEqual(EmptySourceGuard.rsyncEscape(#"a\b*.txt"#), #"a\\b\*.txt"#)
    }

    // Le comptage des dossiers (simulation en arrière-plan) ne retarde pas la fin d'une copie réussie.
    func testDirectoryCountDoesNotDelayTheEnd() async throws {
        let fake = sandbox.appendingPathComponent("fake-rclone").path
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "--dry-run" ] && { sleep 20; exit 0; }; done
        exit 0
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        let runner = TaskRunner(configuration: RunnerConfiguration(rclonePath: fake, workDirectory: sandbox.appendingPathComponent("w")))
        let copy = SyncTask(name: "t", source: .local(path: try folder("s")), destination: .cloud(remote: "x", path: "y"))
        let started = Date()
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result.snapshot.totalDirs, 0, "comptage interrompu : rien de copié, aucun dossier")
    }

    // Course : la copie finit avant que le comptage ait lancé son processus ; celui-ci est arrêté dès son départ.
    func testAuxiliaryStartedAfterStopIsTerminated() async throws {
        let control = RunControl()
        control.stopAuxiliary()
        let process = try ProcessRunner.spawn(executable: "/bin/sleep", arguments: ["20"]) { _ in }
        let started = Date()
        control.registerAuxiliary(process)
        _ = await process.waitForExit()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
