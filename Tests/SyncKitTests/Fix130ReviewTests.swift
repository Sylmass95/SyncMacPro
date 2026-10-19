import XCTest
@testable import SyncKit

/// Relecture de la branche 1.3.0.
final class Fix130AgentReviewTests: XCTestCase {
    // I4 : au démarrage (ou au réveil), la file attend comme le reste (le NAS n'est peut-être pas encore monté).
    func testQueueWaitsForTheStartupHold() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.configuration.startupHold = 60
        let a = makeTask("A", schedule: .manual)
        try h.save([a])
        var state = SchedulerState()
        state.userQueue = [a.id]
        state.userQueueRunning = true
        try h.stateStore.save(state)
        let core = h.makeCore()
        await core.start()
        XCTAssertEqual(h.factory.created, 0, "rien avant la fin de l'attente de démarrage")
        await h.step(core, minutes: 2)
        XCTAssertEqual(h.factory.created, 1)
    }

    // I5 : deux fichiers différents qui échouent pour la même raison sont deux erreurs.
    func testRcloneErrorsKeepTheFileName() {
        let log = RunLog()
        for name in ["a.txt", "b.txt"] {
            if case .error(let text)? = RcloneOutputParser.parse(line: #"{"level":"error","msg":"Failed to copy: permission denied","object":"\#(name)"}"#) {
                log.addError(text)
            }
        }
        XCTAssertEqual(log.errors, 2)
        XCTAssertEqual(log.mainError?.contains("a.txt"), true, log.mainError ?? "")
    }

    // M6 (relevé) : un niveau de journal choisi par l'utilisateur n'entre pas en conflit avec « -v ».
    func testUserLogLevelIsKept() throws {
        var task = SyncTask(name: "t", source: .local(path: "/a"), destination: .cloud(remote: "d", path: "b"))
        task.options.extraArguments = ["--log-level", "ERROR"]
        let args = try RcloneCommandBuilder.command(for: task, run: RunOptions(archiveStamp: "s")).arguments
        XCTAssertFalse(args.contains("-v"))
        task.options.extraArguments = ["-q"]
        XCTAssertFalse(try RcloneCommandBuilder.command(for: task, run: RunOptions(archiveStamp: "s")).arguments.contains("-v"))
    }
}

final class Fix130RunnerReviewTests: IntegrationTestCase {
    // I1 : relance d'un miroir pendant la mise à jour d'un fichier : l'ancienne version archivée n'est pas perdue.
    func testMirrorRestartKeepsTheArchivedOldVersion() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try writeBytes(source + "/gros.bin", megabytes: 20)
        try write(destination + "/gros.bin", "ancienne version")
        for index in 0..<10 { try write(destination + "/g\(index).txt", "x"); try write(source + "/g\(index).txt", "x") }
        var mirror = task(source, destination, mode: .mirror)
        mirror.options.excludes = []
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let frozen = mirror
        let running = Task { try await runner.run(frozen) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        runner.setBandwidth(.unlimited)
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        let archive = destination + "/_ARCHIVE"
        let kept = (FileManager.default.enumerator(atPath: archive)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix("gros.bin") }
            .compactMap { read(archive + "/" + $0) }
        XCTAssertTrue(kept.contains("ancienne version"), "versions archivées : \(kept.map { $0.prefix(20) })")
    }

    // I2 : deux changements rapprochés : c'est le dernier qui s'applique (pas d'abandon pendant les 5 s).
    func testASecondChangeSoonAfterARestartIsApplied() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try writeBytes(source + "/gros.bin", megabytes: 40)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let started = Date()
        let running = Task { try await runner.run(task(source, destination)) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_100_000, downBytesPerSecond: 1_100_000))   // relance
        try await Task.sleep(nanoseconds: 1_000_000_000)
        runner.setBandwidth(.unlimited)                                                                   // dans les 5 s
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "à ~1 Mo/s il faudrait plus de 30 s")
    }

    // I7 : un sous-dossier illisible n'empêche pas de protéger les fichiers vides du reste de la source.
    func testRcloneGuardWorksDespiteAnUnreadableFolder() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/precieux.psb", "")
        try write(destination + "/precieux.psb", "contenu précieux")
        try write(source + "/fermé/x.txt", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source + "/fermé")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source + "/fermé") }
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":local", path: destination))
        copy.options.excludes = []
        _ = try await runner.run(copy)
        XCTAssertEqual(read(destination + "/precieux.psb"), "contenu précieux")
    }
}

final class Fix130RateSenderTests: XCTestCase {
    // I3 : des changements rapprochés partent un par un, et le dernier gagne.
    func testOnlyTheLatestRateIsSentAndInOrder() async {
        let sent = Locked<[Int64?]>([])
        let gate = TestGate()
        let sender = LatestRateSender { rate in
            if sent.get().isEmpty { await gate.wait() }      // le premier envoi est lent
            sent.update { $0.append(rate.downBytesPerSecond) }
            return true
        }
        sender.submit(BandwidthRate(downBytesPerSecond: 1))
        try? await Task.sleep(nanoseconds: 50_000_000)
        sender.submit(BandwidthRate(downBytesPerSecond: 2))
        sender.submit(BandwidthRate(downBytesPerSecond: 3))
        gate.release()
        _ = await eventually { sent.get().count == 2 }
        XCTAssertEqual(sent.get(), [1, 3], "2 est remplacé par 3, et 3 part après 1")
    }
}
