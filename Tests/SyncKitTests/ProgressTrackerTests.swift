import XCTest
@testable import SyncKit

final class ProgressTrackerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func makeTracker(sizes: [String: Int64] = [:], live: Bool = false) -> ProgressTracker {
        ProgressTracker(now: { [unowned self] in self.clock }, fileInfo: { (sizes[$0] ?? 0, live) })
    }

    private func copyFile(_ tracker: ProgressTracker, _ name: String, size: Int64) {
        tracker.apply(.fileStarted(name: name, isNew: nil))
        tracker.apply(.progress(bytes: size, percent: 100, bytesPerSecond: 1_000_000, fileFinished: true))
    }

    func testTotalsFromPlanAndProgress() {
        let tracker = makeTracker(sizes: ["a": 100, "b": 300])
        tracker.start()
        tracker.setPlan(files: ["a": 100, "b": 300], directories: ["d/"])
        copyFile(tracker, "a", size: 100)
        tracker.apply(.fileStarted(name: "b", isNew: nil))
        tracker.apply(.progress(bytes: 150, percent: 50, bytesPerSecond: 50, fileFinished: false))

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.totalFiles, 2)
        XCTAssertEqual(snap.filesDone, 1)
        XCTAssertEqual(snap.totalBytes, 400)
        XCTAssertEqual(snap.doneBytes, 250)
        XCTAssertEqual(snap.currentName, "b")
        XCTAssertEqual(snap.currentPercent, 50)
        XCTAssertEqual(snap.currentETA, 3)             // (300-150)/50
        XCTAssertEqual(snap.overallPercent, 62)
        XCTAssertEqual(snap.totalDirs, 1)
    }

    func testOverallPercentStaysBelow100UntilFinished() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["a": 100], directories: [])
        copyFile(tracker, "a", size: 100)
        XCTAssertEqual(tracker.snapshot().overallPercent, 99)
        tracker.finish()
        XCTAssertEqual(tracker.snapshot().overallPercent, 100)
    }

    /// Régression : après une coupure, rsync renvoie des fichiers déjà copiés ; les octets ne doivent pas être recomptés.
    func testRetransferredFileIsCountedOnce() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["big": 1000], directories: [])
        copyFile(tracker, "big", size: 1000)
        copyFile(tracker, "big", size: 1000)   // reprise : même fichier terminé une seconde fois

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.filesDone, 1)
        XCTAssertEqual(snap.doneBytes, 1000)
        XCTAssertEqual(snap.totalBytes, 1000)
    }

    /// Régression : des fichiers apparus après la simulation font grandir le total au lieu de le dépasser.
    func testNewFilesGrowTheTotal() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["a": 100], directories: ["d/"])
        copyFile(tracker, "a", size: 100)
        copyFile(tracker, "late1", size: 40)
        tracker.apply(.directory(name: "newdir/"))

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.totalFiles, 2)
        XCTAssertEqual(snap.filesDone, 2)
        XCTAssertEqual(snap.totalBytes, 140)
        XCTAssertEqual(snap.doneBytes, 140)
        XCTAssertEqual(snap.totalDirs, 2)
        XCTAssertLessThanOrEqual(snap.doneBytes, snap.totalBytes ?? 0)
        XCTAssertLessThanOrEqual(snap.filesDone, snap.totalFiles ?? 0)
    }

    func testTotalsAreUnknownWithoutPlan() {
        let tracker = makeTracker()
        tracker.start()
        copyFile(tracker, "a", size: 100)
        let snap = tracker.snapshot()
        XCTAssertNil(snap.totalFiles)
        XCTAssertNil(snap.totalBytes)
        XCTAssertNil(snap.overallPercent)
        XCTAssertEqual(snap.filesDone, 1)
    }

    func testTotalsEqualWhatWasCopiedWhenNoPlanEverArrived() {
        let tracker = makeTracker()
        tracker.start()
        copyFile(tracker, "a", size: 100)
        copyFile(tracker, "b", size: 50)
        tracker.finish()
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.totalFiles, 2)
        XCTAssertEqual(snap.totalBytes, 150)
        XCTAssertEqual(snap.overallPercent, 100)
    }

    /// Régression : le temps écoulé du fichier en cours ne doit plus avancer une fois le fichier terminé.
    func testCurrentFileElapsedStopsWhenTheFileCompletes() {
        let tracker = makeTracker()
        tracker.start()
        tracker.apply(.fileStarted(name: "a", isNew: nil))
        clock.addTimeInterval(4)
        tracker.apply(.progress(bytes: 100, percent: 100, bytesPerSecond: 25, fileFinished: true))
        XCTAssertEqual(tracker.snapshot().currentElapsed, 4, accuracy: 0.001)

        clock.addTimeInterval(30)                       // la copie continue (autres fichiers, fin de l'exécution…)
        XCTAssertEqual(tracker.snapshot().currentElapsed, 4, accuracy: 0.001)
    }

    func testElapsedStopsAtFinishAndIgnoresPauses() {
        let tracker = makeTracker()
        tracker.start()
        tracker.apply(.fileStarted(name: "a", isNew: nil))
        clock.addTimeInterval(3)
        tracker.pause()
        clock.addTimeInterval(100)
        tracker.resume()
        clock.addTimeInterval(2)
        XCTAssertEqual(tracker.snapshot().currentElapsed, 5, accuracy: 0.001)

        tracker.finish()
        clock.addTimeInterval(60)
        XCTAssertEqual(tracker.snapshot().currentElapsed, 5, accuracy: 0.001)
        XCTAssertEqual(tracker.snapshot().activeTime, 5, accuracy: 0.001)
    }

    func testAverageSpeedAndETA() {
        let tracker = makeTracker()
        tracker.start()
        tracker.setPlan(files: ["a": 100_000_000, "b": 300_000_000], directories: [])
        copyFile(tracker, "a", size: 100_000_000)
        clock.addTimeInterval(10)

        let snap = tracker.snapshot()
        XCTAssertEqual(snap.activeTime, 10, accuracy: 0.001)
        XCTAssertEqual(snap.averageSpeed, 10_000_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(snap.totalETA), 30, accuracy: 0.01)
    }

    func testPauseDoesNotCountAsActiveTime() {
        let tracker = makeTracker()
        tracker.start()
        clock.addTimeInterval(5)
        tracker.pause()
        clock.addTimeInterval(100)
        tracker.resume()
        clock.addTimeInterval(5)
        XCTAssertEqual(tracker.snapshot().activeTime, 10, accuracy: 0.001)
    }

    func testLiveSamplingGivesSmoothProgressAndSpeed() {
        let tracker = makeTracker(sizes: ["clip": 100_000_000], live: true)
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: nil))
        for step in 1...4 {
            clock.addTimeInterval(1)
            tracker.observeCurrentFileBytes(Int64(step) * 10_000_000)
        }
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.currentBytes, 40_000_000)
        XCTAssertEqual(snap.currentPercent, 40)
        XCTAssertEqual(snap.currentSpeed, 10_000_000, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(snap.currentETA), 6, accuracy: 0.01)
    }

    /// Régression : rsync crée le fichier juste après l'avoir annoncé ; si on le lit trop tard, « il existe déjà ».
    /// L'information « nouveau fichier » vient donc de rsync (isNew), pas d'un test d'existence.
    func testNewFileFlagFromRsyncDrivesLiveSamplingEvenIfTheFileAlreadyExists() {
        let tracker = ProgressTracker(now: { [unowned self] in self.clock }, fileInfo: { _ in (100_000_000, false) })
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: true))
        clock.addTimeInterval(1)
        tracker.observeCurrentFileBytes(10_000_000)
        XCTAssertEqual(tracker.snapshot().currentBytes, 10_000_000)
    }

    func testUpdatedFilesAreNotSampledOnTheDestination() {
        let tracker = ProgressTracker(now: { [unowned self] in self.clock }, fileInfo: { _ in (100, true) })
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: false))
        tracker.observeCurrentFileBytes(100)        // la taille de l'ancienne version n'est pas une progression
        XCTAssertEqual(tracker.snapshot().currentBytes, 0)
    }

    func testLiveSamplingIsIgnoredWhilePaused() {
        let tracker = makeTracker(sizes: ["clip": 100], live: true)
        tracker.start()
        tracker.apply(.fileStarted(name: "clip", isNew: nil))
        tracker.pause()
        tracker.observeCurrentFileBytes(50)
        XCTAssertEqual(tracker.snapshot().currentBytes, 0)
    }

    func testRcloneStatsFillTheSnapshot() throws {
        let tracker = makeTracker()
        tracker.start()
        tracker.apply(RcloneStats(
            bytes: 8_000_000, totalBytes: 32_000_000, speed: 4_000_000, eta: 6, transfers: 2, totalTransfers: 3,
            checks: 0, deletes: 0, errors: 0, elapsedTime: 2, fatalError: false,
            transferring: [RcloneTransferring(name: "big.bin", size: 30_000_000, bytes: 6_000_000, percentage: 20, speed: 3_000_000)]
        ))
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.currentName, "big.bin")
        XCTAssertEqual(snap.currentPercent, 20)
        XCTAssertEqual(try XCTUnwrap(snap.currentETA), 8, accuracy: 0.01)
        XCTAssertEqual(snap.filesDone, 2)
        XCTAssertEqual(snap.totalFiles, 3)
        XCTAssertEqual(snap.overallPercent, 25)
        XCTAssertEqual(snap.totalETA, 6)
        XCTAssertEqual(snap.averageSpeed, 4_000_000)
    }
}
