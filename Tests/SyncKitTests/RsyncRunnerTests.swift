import XCTest
@testable import SyncKit

final class RsyncRunnerTests: IntegrationTestCase {
    func testCopyCopiesEverythingAndReportsProgress() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        try writeBytes("\(src)/sub/big.bin", megabytes: 4)
        let updates = UpdateCollector()

        let result = try await makeRunner(rsync: true).run(task(src, dst)) { updates.add($0) }

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.engine, .rsync)
        XCTAssertEqual(read("\(dst)/a.txt"), "alpha")
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/sub/big.bin")).count, 4 * 1_048_576)
        XCTAssertEqual(result.summary.filesTransferred, 3)
        XCTAssertEqual(result.summary.bytesTransferred, 10 + 4 * 1_048_576)
        XCTAssertEqual(result.snapshot.totalFiles, 3)
        XCTAssertEqual(result.snapshot.overallPercent, 100)
        XCTAssertTrue(updates.phases.contains(.running))
    }

    func testSecondCopyHasNothingToDo() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        let runner = try makeRunner(rsync: true)
        _ = try await runner.run(task(src, dst))
        let again = try await runner.run(task(src, dst))
        XCTAssertEqual(again.status, .succeeded)
        XCTAssertEqual(again.summary.filesTransferred, 0)
    }

    func testSelectedItemsAreCopiedAsFolders() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep/one.txt", "1")
        try write("\(src)/skip/two.txt", "2")
        try write("\(src)/single.txt", "3")
        let result = try await makeRunner(rsync: true).run(task(src, dst, items: ["keep", "single.txt"]))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), ["keep", "single.txt"])
        XCTAssertEqual(read("\(dst)/keep/one.txt"), "1")
    }

    func testMirrorArchivesDeletedAndOverwrittenFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/same.txt", "same")
        try write("\(src)/changed.txt", "new content, longer")
        try write("\(src)/fresh.txt", "fresh")
        try write("\(dst)/same.txt", "same")
        try write("\(dst)/changed.txt", "old")
        try write("\(dst)/gone.txt", "gone")
        // même date de modification pour « same.txt » : rsync le considère identique
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(src)/same.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: "\(dst)/same.txt")

        var options = TaskOptions(excludes: [])
        options.deleteThresholdPercent = 50
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror, options: options))

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst), ["_ARCHIVE", "changed.txt", "fresh.txt", "same.txt"])
        XCTAssertEqual(read("\(dst)/changed.txt"), "new content, longer")
        let archives = names(in: "\(dst)/_ARCHIVE")
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archives[0])/gone.txt"), "gone")
        XCTAssertEqual(read("\(dst)/_ARCHIVE/\(archives[0])/changed.txt"), "old")
        XCTAssertEqual(result.summary.deletions, 1)
    }

    func testMirrorIsBlockedWhenTooManyFilesWouldBeDeletedAndTouchesNothing() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/keep.txt", "keep")
        for index in 1...10 { try write("\(dst)/old\(index).txt", "old") }

        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror))   // seuil par défaut : 25 %

        XCTAssertEqual(result.status, .blocked)
        XCTAssertTrue(result.summary.message?.contains("Bloqué") ?? false, result.summary.message ?? "")
        XCTAssertEqual(names(in: dst).count, 10, "rien ne doit avoir été modifié")
        XCTAssertFalse(exists("\(dst)/keep.txt"))
    }

    func testAnEmptiedSourceCannotWipeTheMirror() async throws {
        let src = try folder("src"), dst = try folder("dst")
        for index in 1...5 { try write("\(dst)/f\(index).txt", "x") }
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror))
        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(names(in: dst).count, 5)
    }

    func testDryRunChangesNothingAndDescribesTheWork() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/b.txt", "bravo")
        let result = try await makeRunner(rsync: true).run(task(src, dst), dryRun: true)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), [])
        XCTAssertEqual(result.summary.filesTransferred, 2)
        XCTAssertTrue(result.summary.message?.contains("Simulation") ?? false)
    }

    func testVerifyOfAMissingSourceFailsInsteadOfReportingNoDifference() async throws {
        let dst = try folder("dst")
        let missing = sandbox.appendingPathComponent("missing").path
        let result = try await makeRunner(rsync: true).run(task(missing, dst, mode: .verify))
        XCTAssertEqual(result.status, .failed, result.summary.message ?? "")
        XCTAssertNotEqual(result.summary.message, "Aucune différence.")
    }

    func testDryRunOfAMissingSourceFailsInsteadOfReportingNothingToDo() async throws {
        let dst = try folder("dst")
        let missing = sandbox.appendingPathComponent("missing").path
        let result = try await makeRunner(rsync: true).run(task(missing, dst), dryRun: true)
        XCTAssertEqual(result.status, .failed, result.summary.message ?? "")
    }

    func testMoveRemovesTheSourceFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/sub/b.txt", "bravo")
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .move))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(read("\(dst)/sub/b.txt"), "bravo")
        XCTAssertFalse(exists("\(src)/a.txt"))
        XCTAssertFalse(exists("\(src)/sub/b.txt"))
    }

    func testVerifyReportsDifferences() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/same.txt", "same")
        try write("\(dst)/same.txt", "same")
        let runner = try makeRunner(rsync: true)
        let identical = try await runner.run(task(src, dst, mode: .verify))
        XCTAssertEqual(identical.status, .succeeded)

        try write("\(src)/changed.txt", "AAA")
        try write("\(dst)/changed.txt", "BBB")
        let different = try await runner.run(task(src, dst, mode: .verify))
        XCTAssertEqual(different.status, .failed)
        XCTAssertTrue(different.summary.message?.contains("changed.txt") ?? false)
    }

    func testVerifyAfterCopyPassesOnAGoodCopy() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        var options = TaskOptions(excludes: [])
        options.verifyAfterCopy = true
        let updates = UpdateCollector()
        let result = try await makeRunner(rsync: true).run(task(src, dst, options: options)) { updates.add($0) }
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(updates.phases.contains(.verifying))
    }

    func testExcludesAreHonored() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try write("\(src)/a.txt", "alpha")
        try write("\(src)/.DS_Store", "junk")
        try write("\(src)/notes.tmp", "junk")
        let result = try await makeRunner(rsync: true).run(task(src, dst, options: TaskOptions(excludes: [".DS_Store", "*.tmp"])))
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(names(in: dst), ["a.txt"])
    }

    func testMissingSourceFailsWithAMessage() async throws {
        let dst = try folder("dst")
        let result = try await makeRunner(rsync: true).run(task(sandbox.appendingPathComponent("nope").path, dst))
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.summary.message?.isEmpty ?? true)
    }

    func testRsyncOnlyModeOnRcloneOnlyTaskIsRejected() async throws {
        let src = try folder("src"), dst = try folder("dst")
        let bad = task(src, dst, mode: .copy, options: TaskOptions(excludes: [], forcedEngine: .rsync))
        var cloud = bad
        cloud.destination = .cloud(remote: "gdrive", path: "")
        let runner = try makeRunner(rsync: true)   // hors du `do` : un rsync absent ignore le test au lieu de le faire échouer
        do {
            _ = try await runner.run(cloud)
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? EngineSelectionError, .cloudRequiresRclone)
        }
    }

    func testMissingBinaryThrows() async throws {
        let src = try folder("src"), dst = try folder("dst")
        do {
            _ = try await makeRunner().run(task(src, dst))
            XCTFail("aurait dû échouer")
        } catch {
            XCTAssertEqual(error as? RunnerError, .binaryMissing(.rsync))
        }
    }

    // MARK: cas difficiles

    func testAwkwardFileNamesSurviveTheWholePipeline() async throws {
        let src = try folder("src"), dst = try folder("dst")
        let names = ["Rushes été/clip n°1 (copie) | v2.mov", "-leading-dash.txt", "with space.txt", "日本語.txt", "a;b&c$d.txt"]
        for name in names { try write("\(src)/\(name)", "content of \(name)") }

        let result = try await makeRunner(rsync: true).run(task(src, dst))

        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.summary.filesTransferred, names.count)
        for name in names { XCTAssertEqual(read("\(dst)/\(name)"), "content of \(name)", name) }
    }

    func testMirrorToAMissingDestinationCreatesIt() async throws {
        let src = try folder("src")
        try write("\(src)/a.txt", "alpha")
        let dst = sandbox.appendingPathComponent("not/yet/there").path
        let result = try await makeRunner(rsync: true).run(task(src, dst, mode: .mirror))
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read("\(dst)/a.txt"), "alpha")
    }

    /// Le NAS est débranché ou le dossier effacé en pleine copie : l'exécution doit échouer avec un message, pas rester bloquée.
    func testDestinationVanishingMidRunFailsInsteadOfHanging() async throws {
        let src = try folder("src"), dst = try folder("dst")
        for index in 1...6 { try writeBytes("\(src)/clip\(index).bin", megabytes: 3) }
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 4_000
        let runner = try makeRunner(rsync: true)
        let updates = UpdateCollector()
        let frozenOptions = options          // Swift 5.10 refuse de capturer une variable modifiable dans une tâche concurrente
        let run = Task { try await runner.run(task(src, dst, options: frozenOptions)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.filesDone ?? 0) >= 1 }
        try FileManager.default.removeItem(atPath: dst)

        let result = try await withThrowingTaskGroup(of: RunResult?.self) { group -> RunResult? in
            group.addTask { try await run.value }
            group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let finished = try XCTUnwrap(result, "l'exécution est restée bloquée")
        XCTAssertEqual(finished.status, .failed)
        XCTAssertFalse(finished.summary.message?.isEmpty ?? true)
    }

    /// La destination ne peut pas exister (son « dossier parent » est un fichier) : échec clair, rien de copié.
    func testDestinationThatCannotBeCreatedFailsWithAMessage() async throws {
        let src = try folder("src")
        try write("\(src)/a.txt", "alpha")
        let blocker = try write("\(sandbox.path)/blocker", "je suis un fichier")

        let result = try await makeRunner(rsync: true).run(task(src, "\(blocker)/dest"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.summary.message?.isEmpty ?? true)
        XCTAssertEqual(read(blocker), "je suis un fichier")
    }

    // MARK: pause, reprise, arrêt

    func testPauseFreezesTheCopyAndResumeFinishesIt() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 16)
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 6_000                        // ~3 secondes pour 16 Mo
        let runner = try makeRunner(rsync: true)
        let updates = UpdateCollector()
        let frozenOptions = options          // Swift 5.10 refuse de capturer une variable modifiable dans une tâche concurrente
        let run = Task { try await runner.run(task(src, dst, options: frozenOptions)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 500_000 }
        runner.pause()
        try await Task.sleep(nanoseconds: 700_000_000)
        let frozen = updates.latest?.currentBytes ?? 0
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(updates.latest?.currentBytes ?? 0, frozen, "pas de progression pendant la pause")
        XCTAssertLessThan(frozen, 16 * 1_048_576)

        runner.resume()
        let result = try await run.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/big.bin")).count, 16 * 1_048_576)
        XCTAssertGreaterThan(result.summary.durationSeconds, 1)
    }

    func testStopEndsTheRunAndAnInterruptedFileCanBeResumed() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/big.bin", megabytes: 16)
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 6_000
        let runner = try makeRunner(rsync: true)
        let updates = UpdateCollector()
        let frozenOptions = options          // Swift 5.10 refuse de capturer une variable modifiable dans une tâche concurrente
        let run = Task { try await runner.run(task(src, dst, options: frozenOptions)) { updates.add($0) } }

        try await waitUntil { (updates.latest?.currentBytes ?? 0) > 500_000 }
        runner.stop()
        let stopped = try await run.value
        XCTAssertEqual(stopped.status, .stopped)

        // nouvelle exécution : elle termine le fichier, sans erreur
        let resumed = try await makeRunner(rsync: true).run(task(src, dst))
        XCTAssertEqual(resumed.status, .succeeded, resumed.summary.message ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dst)/big.bin")).count, 16 * 1_048_576)
    }

    func testProgressIsLiveForFastFiles() async throws {
        let src = try folder("src"), dst = try folder("dst")
        try writeBytes("\(src)/clip.bin", megabytes: 12)
        var options = TaskOptions(excludes: [])
        options.bandwidthLimitKBps = 8_000                        // ~1,5 s : rsync n'affiche qu'une ligne par seconde
        let updates = UpdateCollector()
        let result = try await makeRunner(rsync: true).run(task(src, dst, options: options)) { updates.add($0) }
        XCTAssertEqual(result.status, .succeeded)
        let distinctProgress = Set(updates.snapshots.map(\.currentBytes).filter { $0 > 0 })
        XCTAssertGreaterThanOrEqual(distinctProgress.count, 4, "la mesure directe donne bien plus de points que rsync")
    }
}
