import XCTest
@testable import SyncKit

/// 1.6.8 : le partage du NAS se démonte pendant une copie (coupure du tunnel WARP, essai réel du 18/10) ; rclone a
/// tourné des heures dans le vide (13 000 « mkdir /Volumes/… : permission denied »). Le partage est surveillé pendant
/// la copie : disparu, la copie s'arrête et la tâche attend le NAS, comme au départ.
final class ShareLostRunnerTests: IntegrationTestCase {
    func slowCopy(_ shares: FakeShares) throws -> (TaskRunner, SyncTask) {
        let source = try folder("Bureau")
        try writeBytes(source + "/gros.bin", megabytes: 10)
        var configuration = RunnerConfiguration(rsyncPath: try rsyncPath(), workDirectory: sandbox.appendingPathComponent("w"))
        configuration.shares = shares
        configuration.shareWatchInterval = 0.2
        let runner = TaskRunner(configuration: configuration)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))   // ~10 s
        let task = SyncTask(name: "test", source: .local(path: source),
                            destination: .network(url: "smb://moi@nas/NAS", mountPath: shares.base + "/NAS/Sauvegarde"))
        return (runner, task)
    }

    func testAShareThatDisappearsDuringTheCopyStopsItAndIsReportedUnavailable() async throws {
        let shares = FakeShares(base: try folder("Volumes"))
        let (runner, task) = try slowCopy(shares)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            shares.mounted.set([])   // démonté
        }
        let started = Date()
        let result = try await runner.run(task)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "arrêtée sans attendre la fin")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.shareUnavailable, "NAS")
        let message = try XCTUnwrap(result.summary.message)
        XCTAssertTrue(message.contains("démonté pendant la copie"), message)
    }

    func testAStopByTheUserIsStillAStop() async throws {
        let shares = FakeShares(base: try folder("Volumes"))
        let (runner, task) = try slowCopy(shares)
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            runner.stop()
        }
        let result = try await runner.run(task)
        XCTAssertEqual(result.status, .stopped)
        XCTAssertNil(result.shareUnavailable)
    }
}

final class ShareLostAgentTests: XCTestCase {
    /// Une copie déjà avancée quand le partage est perdu reste dans l'historique (interrompue), puis la tâche attend.
    func testAPartialCopyIsKeptAsInterruptedWhileTheTaskWaits() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.configuration.openApp = {}
        let task = SyncTask(name: "A", source: .network(url: "smb://moi@nas/NAS", mountPath: "/Volumes/NAS/A"),
                            destination: .local(path: "/copie/A"))
        try h.save([task])
        h.factory.unavailableNames.set(["A"])
        h.factory.copiedBeforeLoss.set(120)
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        let records = try h.history.list(taskID: task.id)
        XCTAssertEqual(records.map(\.status), [.interrupted])
        XCTAssertEqual(records.first?.summary?.filesTransferred, 120)
        XCTAssertTrue(h.notifier.messages.get().isEmpty)
        let state = await core.status().tasks.first { $0.id == task.id }?.state
        guard case .waiting(let reason) = state else { return XCTFail("en attente attendu") }
        XCTAssertTrue(reason.contains("injoignable"), reason)
    }
}
