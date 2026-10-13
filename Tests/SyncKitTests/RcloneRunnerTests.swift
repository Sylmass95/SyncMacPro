import XCTest
@testable import SyncKit

final class RcloneRunnerTests: IntegrationTestCase {
    private func rcloneTask(_ source: String, _ destination: String, mode: SyncMode = .copy,
                            options: TaskOptions = TaskOptions(excludes: [])) -> SyncTask {
        task(source, destination, mode: mode, options: options)
    }

    private var forced: TaskOptions { TaskOptions(excludes: [], forcedEngine: .rclone) }

    /// Entre deux dossiers locaux, rclone fait une « copie côté serveur » instantanée et sans progression.
    /// `--disable Copy` force un vrai flux de données, comme avec un service en ligne.
    private var streaming: TaskOptions {
        TaskOptions(excludes: [], bandwidthLimitKBps: 6_000, forcedEngine: .rclone, extraArguments: ["--disable", "Copy"])
    }

    func testCopyWithRclone() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        try writeBytes("\(src)/sub/big.bin", megabytes: 3)
        let updates = UpdateCollector()

        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, options: forced)) { updates.add($0) }

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.engine, .rclone)
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertEqual(result.summary.filesTransferred, 3)
        XCTAssertEqual(result.snapshot.totalFiles, 3)
        XCTAssertEqual(result.snapshot.overallPercent, 100)
        XCTAssertFalse(updates.snapshots.isEmpty)
    }

    func testDryRunChangesNothing() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/b.txt", "bravo")
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, options: forced), dryRun: true)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), [])
        XCTAssertEqual(result.summary.filesTransferred, 2)
    }

    func testMirrorArchivesDeletedAndOverwrittenFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/same.txt", "same")
        try write("\(src)/changed.txt", "new content, longer")
        try write("\(src)/fresh.txt", "fresh")
        try write("\(dst)/same.txt", "same")
        try write("\(dst)/changed.txt", "old")
        try write("\(dst)/gone.txt", "gone")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(src)/same.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(dst)/same.txt")

        var options = forced
        options.deleteThresholdPercent = 50
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: options))

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst), ["_ARCHIVE", "changed.txt", "fresh.txt", "same.txt"])
        let archive = try XCTUnwrap(names(in: "\(dst)/_ARCHIVE").first)
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archive)/gone.txt"), "gone")
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archive)/changed.txt"), "old")
        XCTAssertEqual(result.summary.deletions, 1)
    }

    func testMirrorIsBlockedBeforeTouchingAnything() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep.txt", "keep")
        for index in 1...10 { try write("\(dst)/old\(index).txt", "old") }

        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: forced))

        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(names(in: dst).count, 10)
        XCTAssertFalse(exists("\(dst)/keep.txt"))
    }

    func testMirrorToAMissingDestinationJustCopies() async throws {
        let src = try folder("src")
        try write("\(src)/a.txt", "alpha")
        let dst = sandbox.appendingPathComponent("newdest").path
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: forced))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read("\(dst)/a.txt"), "alpha")
    }

    func testMoveRemovesTheSource() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .move, options: forced))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertFalse(exists("\(src)/a.txt"))
    }

    func testVerify() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(dst)/a.txt", "alpha")
        let runner = try makeRunner(rclone: true)
        let same = try await runner.run(rcloneTask(src, dst, mode: .verify, options: forced))
        XCTAssertEqual(same.status, .succeeded)

        try write("\(dst)/a.txt", "different")
        let different = try await runner.run(rcloneTask(src, dst, mode: .verify, options: forced))
        XCTAssertEqual(different.status, .failed)
        XCTAssertTrue(different.summary.message?.contains("a.txt") ?? false)
    }

    func testSelectedItemsOnly() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep/one.txt", "1")
        try write("\(src)/skip/two.txt", "2")
        try write("\(src)/single.txt", "3")
        let t = task(src, dst, options: forced, items: ["keep", "single.txt"])
        let result = try await makeRunner(rclone: true).run(t)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), ["keep", "single.txt"])
    }

    // MARK: bisync

    // Essai réel 1.1.1 : rclone nomme son verrou d'après les deux chemins ; au-delà de 255 caractères, bisync échouait.
    func testBisyncWorksWithLongPaths() async throws {
        let long = String(repeating: "dossier-au-nom-tres-long-", count: 6)    // 150 caractères par niveau
        let one = try folder("\(long)/un/\(long)"), two = try folder("\(long)/deux/\(long)")
        XCTAssertGreaterThan(one.count + two.count, 400)
        for index in 1...8 { try write("\(one)/f\(index).txt", "x") }
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)
        let first = try await runner.run(sync)
        XCTAssertEqual(first.status, .succeeded, first.summary.message ?? "")
        try write("\(two)/nouveau.txt", "depuis deux")
        let second = try await runner.run(sync)
        XCTAssertEqual(second.status, .succeeded, second.summary.message ?? "")
        XCTAssertEqual(read("\(one)/nouveau.txt"), "depuis deux")
        XCTAssertFalse((second.summary.message ?? "").contains("\u{1B}["), "pas de codes couleur dans les messages")
    }

    func testBisyncInitializesThenPropagatesChangesAndDeletions() async throws {
        let one = try folder("one"), two = try folder("two")
        try write("\(one)/a.txt", "from-one")
        try write("\(two)/b.txt", "from-two")
        for index in 1...8 { try write("\(one)/common\(index).txt", "x") }   // assez de fichiers pour que 1 suppression reste sous le seuil
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)

        let first = try await runner.run(sync)
        XCTAssertEqual(first.status, .succeeded, first.summary.message ?? "")
        XCTAssertTrue(exists("\(one)/b.txt"))           // initialisation : chaque côté reçoit ce qui lui manque
        XCTAssertTrue(exists("\(two)/a.txt"))
        XCTAssertEqual(names(in: one).count, 10)
        XCTAssertEqual(names(in: two).count, 10)

        try write("\(one)/c.txt", "new-in-one")
        try FileManager.default.removeItem(atPath: "\(two)/a.txt")
        let second = try await runner.run(sync)
        XCTAssertEqual(second.status, .succeeded, second.summary.message ?? "")
        XCTAssertEqual(read("\(two)/c.txt"), "new-in-one")
        XCTAssertFalse(exists("\(one)/a.txt"), "la suppression est propagée")
        let archived = try XCTUnwrap(names(in: "\(one)/_ARCHIVE").first, "aucune archive créée")
        XCTAssertEqual(read("\(one)/_ARCHIVE/\(archived)/a.txt"), "from-one", "et l'ancienne version est archivée")
    }

    func testBisyncBlocksAMassDeletionAndChangesNothing() async throws {
        let one = try folder("one"), two = try folder("two")
        for index in 1...10 { try write("\(one)/f\(index).txt", "x") }
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)
        _ = try await runner.run(sync)
        XCTAssertEqual(names(in: two).count, 10)

        for index in 1...6 { try FileManager.default.removeItem(atPath: "\(one)/f\(index).txt") }   // 60 % supprimés
        let result = try await runner.run(sync)

        XCTAssertEqual(result.status, .blocked, result.summary.message ?? "")
        XCTAssertEqual(names(in: two).count, 10, "l'autre côté n'est pas touché")
    }

    func testBisyncStateIsPerTask() async throws {
        let one = try folder("one"), two = try folder("two")
        try write("\(one)/a.txt", "x")
        let runner = try makeRunner(rclone: true)
        let sync = rcloneTask(one, two, mode: .bidirectional)
        _ = try await runner.run(sync)
        let workdir = sandbox.appendingPathComponent("work/bisync/\(sync.id.uuidString)")
        XCTAssertTrue(TaskRunner.hasBisyncState(at: workdir))
        XCTAssertFalse(TaskRunner.hasBisyncState(at: sandbox.appendingPathComponent("work/bisync/\(UUID().uuidString)")))
    }

    // MARK: relecture finale (I2, I3, I4)

    /// I2 : l'archive grossit avec le temps ; elle ne doit pas diluer le pourcentage de suppressions.
    func testMirrorGuardDoesNotCountTheArchiveFolderAsLiveFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")                 // source vidée
        for index in 1...4 { try write("\(dst)/live\(index).txt", "x") }
        for index in 1...60 { try write("\(dst)/_ARCHIVE/2026-01-01_00-00-00/old\(index).txt", "x") }

        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: forced))

        XCTAssertEqual(result.status, .blocked, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst).filter { $0 != "_ARCHIVE" }.count, 4, "les fichiers vivants ne doivent pas être touchés")
    }

    /// I3 (a) : après un miroir, l'archive existe côté destination : ce n'est pas une différence.
    func testVerifyAfterCopyIgnoresTheArchiveAfterAMirror() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "new content, longer")
        try write("\(dst)/a.txt", "old")
        try write("\(dst)/gone.txt", "gone")
        var options = forced
        options.deleteThresholdPercent = 100
        options.verifyAfterCopy = true
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, mode: .mirror, options: options))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
    }

    /// I3 (b) : copier vers un dossier qui contient déjà d'autres fichiers est normal.
    func testVerifyAfterCopyAcceptsForeignFilesOnTheDestination() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(dst)/foreign.txt", "not ours")
        var options = forced
        options.verifyAfterCopy = true
        let result = try await makeRunner(rclone: true).run(rcloneTask(src, dst, options: options))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
    }

    /// I3 (c) : avec une sélection, seuls les éléments choisis sont vérifiés.
    func testVerifyAfterCopyOnASelectionOnlyChecksTheSelection() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep/one.txt", "1")
        try write("\(src)/other.txt", "not selected")
        var options = forced
        options.verifyAfterCopy = true
        let result = try await makeRunner(rclone: true).run(task(src, dst, options: options, items: ["keep"]))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst), ["keep"])
    }

    /// I4 : un avertissement de rclone sur stderr (ici : fichier de configuration absent) ne doit pas
    /// fausser le décompte des fichiers et bloquer une sauvegarde sans danger.
    func testGuardIsNotFooledByNoticesOnStderr() async throws {
        let src = try folder("src"), dst = try folder("dst")
        for index in 1...9 { try write("\(src)/f\(index).txt", "x") }
        for index in 1...10 { try write("\(dst)/f\(index).txt", "x") }      // 1 suppression sur 10 : 10 %, sous le seuil
        let runner = TaskRunner(configuration: RunnerConfiguration(
            rclonePath: try rclonePath(),
            rcloneConfigPath: sandbox.appendingPathComponent("no-such-file.conf").path,
            workDirectory: sandbox.appendingPathComponent("work")
        ))
        let result = try await runner.run(rcloneTask(src, dst, mode: .mirror, options: forced))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertFalse(exists("\(dst)/f10.txt"))
    }

    // MARK: pause et arrêt

    func testPauseAndResumeWithRclone() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 12)
        let runner = try makeRunner(rclone: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(rcloneTask(src, dst, options: streaming)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 300_000 }
        runner.pause()
        try await Task.sleep(nanoseconds: 800_000_000)
        let frozen = updates.snapshots.count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(updates.snapshots.count, frozen, "rclone figé : plus de statistiques")

        runner.resume()
        let result = try await run.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/big.bin")).count, 12 * 1_048_576)
    }

    func testStopWithRclone() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 12)
        let runner = try makeRunner(rclone: true)
        let updates = UpdateCollector()
        let run = Task { try await runner.run(rcloneTask(src, dst, options: streaming)) { updates.add($0) } }
        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 300_000 }
        runner.stop()
        let result = try await run.value
        XCTAssertEqual(result.status, .stopped)
    }
}
