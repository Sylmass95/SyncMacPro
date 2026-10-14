import XCTest
@testable import SyncKit

/// Constats de la campagne d'incidents sur la 1.2.1 (disque plein, débranché, figé ; conflits ; défauts mineurs).
final class Fix122ErrorTextTests: XCTestCase {
    // Disque plein : la vraie cause, pas le « Broken pipe » qui en découle.
    func testFullDiskNamesTheCauseNotTheBrokenPipe() {
        let text = EngineErrorText.summary(errors: [
            #"rsync: [receiver] write failed on "/Volumes/X/copie/f22.bin": No space left on device (28)"#,
            "rsync error: error in file IO (code 11) at receiver.c(660) [receiver=3.5.1]",
            "rsync: [sender] write error: Broken pipe (32)",
        ], total: 3)
        XCTAssertEqual(text?.hasPrefix("Plus de place sur le disque de destination."), true, text ?? "")
        XCTAssertEqual(text?.contains("No space left on device"), true)
        XCTAssertEqual(text?.contains("Broken pipe"), false)
    }

    func testUnpluggedDiskIsExplained() {
        let text = EngineErrorText.summary(errors: [
            #"rsync: [receiver] write failed on "/Volumes/X/f17.bin": Input/output error (5)"#,
            "rsync error: error in file IO (code 11) at receiver.c(660) [receiver=3.5.1]",
            "rsync: [sender] write error: Broken pipe (32)",
        ], total: 3)
        XCTAssertEqual(text?.hasPrefix("Erreur de lecture ou d'écriture : le disque ou le NAS a peut-être été débranché."), true, text ?? "")
    }

    func testMissingSourceIsExplained() {
        let text = EngineErrorText.summary(errors: [
            #"rsync: [sender] change_dir "/Volumes/Photos/docs" failed: No such file or directory (2)"#,
            "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1412) [sender=3.5.1]",
        ], total: 2)
        XCTAssertEqual(text?.hasPrefix("Dossier introuvable (disque débranché ou dossier déplacé ?)."), true, text ?? "")
    }

    func testRcloneDirectoryNotFoundIsExplained() {
        let text = EngineErrorText.summary(errors: ["Attempt 3/3 failed with 1 errors and: directory not found"], total: 1)
        XCTAssertEqual(text?.hasPrefix("Dossier introuvable (disque débranché ou dossier déplacé ?)."), true, text ?? "")
    }

    func testManyErrorsAreCounted() {
        let errors = (1...5).map { #"rsync: [sender] send_files failed to open "/s/f\#($0)": Permission denied (13)"# }
        let text = EngineErrorText.summary(errors: errors, total: 40)
        XCTAssertEqual(text?.hasPrefix("Accès refusé."), true, text ?? "")
        XCTAssertEqual(text?.hasSuffix("(40 erreurs au total : voir le journal)"), true, text ?? "")
        XCTAssertEqual(text?.contains("/s/f1"), true, "la première erreur est la plus parlante")
    }

    func testOnlySummaryLinesAreKeptAsIs() {
        let line = "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1412) [sender=3.5.1]"
        XCTAssertEqual(EngineErrorText.summary(errors: [line], total: 1), line)
        XCTAssertNil(EngineErrorText.summary(errors: [], total: 0))
    }

    func testRunLogKeepsTheFirstErrorsEvenAfterMany() {
        let log = RunLog()
        log.addError("rsync: première cause: No space left on device (28)")
        for index in 0..<100 { log.addError("rsync: [sender] write error: Broken pipe (32) \(index)") }
        XCTAssertEqual(log.mainError?.contains("première cause"), true, log.mainError ?? "")
    }
}

final class Fix122VerifyRetryTests: XCTestCase {
    // Différences trouvées : relancer ne changerait rien.
    func testVerifyWithDifferencesIsNotRetried() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.failed)
        h.factory.retryable.set(false)
        let check = makeTask("Vérif", schedule: .manual, mode: .verify)
        try h.save([check])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(check.id)
        await core.waitForIdle()
        let next = await core.status().tasks.first?.nextDue
        XCTAssertNil(next)
    }

    // Vérification impossible (NAS absent, réseau coupé) : panne passagère, nouvel essai plus tard.
    func testVerifyThatCouldNotRunIsRetried() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.factory.status.set(.failed)
        let check = makeTask("Vérif", schedule: .manual, mode: .verify)
        try h.save([check])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(check.id)
        await core.waitForIdle()
        let next = await core.status().tasks.first?.nextDue
        XCTAssertNotNil(next)
    }
}

final class Fix122RunnerTests: IntegrationTestCase {
    /// Faux rsync : écrit une ligne, puis ne fait plus rien (comme face à un NAS figé), sauf pour `--version`.
    private func fakeEngine(_ body: String) throws -> String {
        let path = sandbox.appendingPathComponent("fake-rsync").path
        let script = """
        #!/bin/sh
        case "$1" in --version) echo "rsync  version 3.5.1  protocol version 33"; exit 0;; esac
        for a in "$@"; do [ "$a" = "-n" ] && exit 0; [ "$a" = "-rtn" ] && exit 0; done
        \(body)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func runner(engine: String, stallTimeout: TimeInterval) -> TaskRunner {
        TaskRunner(configuration: RunnerConfiguration(
            rsyncPath: engine, workDirectory: sandbox.appendingPathComponent("work"),
            sampleInterval: 0.05, stallTimeout: stallTimeout, stallCheckInterval: 0.1
        ))
    }

    // Moteur figé : l'exécution s'arrête d'elle-même au bout du délai et sera retentée (échec, pas blocage infini).
    func testStalledEngineIsStoppedAfterTheTimeout() async throws {
        let engine = try fakeEngine("echo 'sending incremental file list'\nsleep 60\n")
        let started = Date()
        let result = try await runner(engine: engine, stallTimeout: 1)
            .run(task(try folder("s"), try folder("d")))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.summary.message?.hasPrefix("Aucune progression depuis"), true, result.summary.message ?? "")
    }

    // Une pause de l'utilisateur fige le moteur sans que cela compte comme un blocage.
    func testPauseDoesNotCountAsAStall() async throws {
        let engine = try fakeEngine("for i in 1 2 3 4 5 6 7 8; do echo \"ligne $i\"; sleep 0.2; done\n")
        let runner = runner(engine: engine, stallTimeout: 1)
        let source = try folder("s"), destination = try folder("d")
        let running = Task { try await runner.run(task(source, destination)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        runner.pause()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        runner.resume()
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
    }

    // Un programme qui travaille sans rien écrire (calcul d'empreintes d'un gros fichier) n'est pas figé.
    func testBusySilentEngineIsNotAStall() async throws {
        let engine = try fakeEngine("end=$(( $(date +%s) + 3 )); while [ $(date +%s) -lt $end ]; do :; done\n")
        let result = try await runner(engine: engine, stallTimeout: 1)
            .run(task(try folder("s"), try folder("d")))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
    }

    // Première exécution bidirectionnelle vers un dossier qui n'existe pas encore : il est créé.
    func testBidirectionalCreatesAMissingDestination() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("a")
        try write(source + "/x.txt", "x")
        let destination = sandbox.appendingPathComponent("b/sous-dossier").path
        let result = try await runner.run(task(source, destination, mode: .bidirectional))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read(destination + "/x.txt"), "x")
    }

    // bisync exige une réinitialisation (ici : un changement de casse seul sur un disque insensible à la casse).
    // Elle est faite automatiquement : rien n'est supprimé, la version écrasée est archivée.
    func testBisyncThatNeedsAResyncRecoversByItself() async throws {
        let runner = try makeRunner(rclone: true)
        let a = try folder("a"), b = try folder("b")
        try write(a + "/Casse.txt", "casse")
        try write(a + "/commun.txt", "commun")
        for index in 0..<20 { try write(a + "/f\(index).txt", "\(index)") }   // sous le seuil de suppressions
        let bidirectional = task(a, b, mode: .bidirectional)
        let first = try await runner.run(bidirectional)
        XCTAssertEqual(first.status, .succeeded, first.summary.message ?? "")
        try FileManager.default.moveItem(atPath: b + "/Casse.txt", toPath: b + "/tmp")
        try FileManager.default.moveItem(atPath: b + "/tmp", toPath: b + "/CASSE.txt")
        try write(a + "/nouveau.txt", "nouveau")
        let second = try await runner.run(bidirectional)
        XCTAssertEqual(second.status, .succeeded, second.summary.message ?? "")
        XCTAssertEqual(second.summary.message?.contains("réinitialisé"), true, second.summary.message ?? "")
        XCTAssertEqual(read(b + "/nouveau.txt"), "nouveau")
        XCTAssertEqual(read(a + "/commun.txt"), "commun")
        let third = try await runner.run(bidirectional)
        XCTAssertEqual(third.status, .succeeded, third.summary.message ?? "")
    }
}

final class Fix122MinorTests: XCTestCase {
    // Un programme qui laisse un sous-processus tenir la sortie ouverte : sa première ligne est quand même lue.
    func testFirstLineIsReadEvenIfAGrandchildKeepsTheOutputOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("rclone")
        try "#!/bin/sh\necho 'rclone v1.75.1'\n(sleep 20) &\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let started = Date()
        XCTAssertEqual(BinaryLocator.firstLine(of: fake.path, arguments: ["version"], timeout: 5), "rclone v1.75.1")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // « log » : un nom ambigu le reste, même si une copie ponctuelle porte ce nom.
    func testLogReferenceStaysAmbiguous() {
        let tasks = [makeTask("Photos A"), makeTask("Photos B")]
        XCTAssertEqual(TaskReference.logTarget("Photos", in: tasks), .failure(.ambiguous("Photos", ["Photos A", "Photos B"])))
        XCTAssertEqual(TaskReference.logTarget("Photos A", in: tasks), .success(tasks[0]))
        XCTAssertEqual(TaskReference.logTarget("Copie du soir", in: tasks), .failure(.notFound("Copie du soir")))
    }
}
