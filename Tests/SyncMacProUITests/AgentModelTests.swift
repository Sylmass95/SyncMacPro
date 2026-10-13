import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelTests: XCTestCase {
    let id = UUID()
    var agent: FakeAgent!
    var sleeper: ManualSleeper!
    var model: AgentModel!

    override func setUp() async throws {
        agent = FakeAgent()
        sleeper = ManualSleeper()
        model = AgentModel(agent: agent, sleeper: sleeper)
    }

    override func tearDown() async throws { model.shutdown() }

    func connect(_ status: AgentStatus? = nil) async {
        agent.setStatus(.success(status ?? makeStatus([AgentTaskInfo(id: id, name: "t", state: .idle)])))
        model.start()
        let ok = await eventually { self.model.connection == .connected && self.agent.watchStarts == 1 }
        XCTAssertTrue(ok, "la connexion doit aboutir")
    }

    func testConnectsAndLoadsStatusTasksAndHistory() async {
        let task = SyncTask(id: id, name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        agent.setTasks([task])
        await connect()
        XCTAssertEqual(model.status?.tasks.count, 1)
        XCTAssertEqual(model.tasks[id]?.name, "t")
        XCTAssertEqual(agent.historyCalls, 1)
        XCTAssertNil(model.historyError)
    }

    func testInitialProgressComesFromTheStatus() async {
        var info = ProgressInfo(TransferSnapshot())
        info.doneBytes = 123
        await connect(makeStatus([AgentTaskInfo(id: id, name: "t", state: .running, progress: info)]))
        XCTAssertEqual(model.progress[id]?.doneBytes, 123)
    }

    func testProgressEventsAreAppliedWithoutAnyRefetch() async {
        await connect()
        var info = ProgressInfo(TransferSnapshot())
        info.overallPercent = 42
        agent.emit(.progress(id, info))
        let seen = await eventually { self.model.progress[id]?.overallPercent == 42 }
        XCTAssertTrue(seen)
        XCTAssertEqual(agent.statusCalls, 1, "l'avancement ne déclenche aucune relecture")
    }

    func testABurstOfEventsCausesASingleRefresh() async {
        await connect()
        agent.emit(.stateChanged)
        agent.emit(.taskStarted(id))
        agent.emit(.stateChanged)
        let waiting = await eventually { self.sleeper.requests.contains(0.25) }
        XCTAssertTrue(waiting)
        sleeper.release(seconds: 0.25)
        let refreshed = await eventually { self.agent.statusCalls == 2 }
        XCTAssertTrue(refreshed)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(agent.statusCalls, 2, "une seule relecture pour toute la rafale")
        XCTAssertEqual(sleeper.requests.filter { $0 == 0.25 }.count, 1)
    }

    func testTaskFinishedClearsProgressAndReloadsHistory() async {
        await connect()
        var info = ProgressInfo(TransferSnapshot())
        info.overallPercent = 80
        agent.emit(.progress(id, info))
        _ = await eventually { self.model.progress[id] != nil }
        agent.emit(.taskFinished(id, .succeeded, nil))
        _ = await eventually { self.sleeper.requests.contains(0.25) }
        XCTAssertNil(model.progress[id])
        sleeper.release(seconds: 0.25)
        let reloaded = await eventually { self.agent.historyCalls == 2 }
        XCTAssertTrue(reloaded, "une fin d'exécution recharge l'historique")
    }

    func testSafetyRefreshRunsEveryThirtySeconds() async {
        await connect()
        let waiting = await eventually { self.sleeper.requests.contains(30) }
        XCTAssertTrue(waiting)
        sleeper.release(seconds: 30)
        let refreshed = await eventually { self.agent.statusCalls >= 2 }
        XCTAssertTrue(refreshed)
    }

    func testUnreachableAgentIsRetriedWithGrowingDelays() async {
        agent.setStatus(.failure(AgentClientError.unreachable))
        model.start()
        for count in 1...6 {
            let asked = await eventually { self.sleeper.requests.count == count }
            XCTAssertTrue(asked, "attente n°\(count)")
            sleeper.releaseAll()
        }
        XCTAssertEqual(Array(sleeper.requests.prefix(6)), [1, 2, 4, 8, 15, 15])
        XCTAssertEqual(model.connection, .unreachable)
    }

    func testLostConnectionReconnectsByItself() async {
        await connect()
        agent.endWatch()
        let reconnecting = await eventually { self.model.connection == .reconnecting(attempt: 1) }
        XCTAssertTrue(reconnecting)
        let asked = await eventually { self.sleeper.requests.contains(1) }
        XCTAssertTrue(asked)
        sleeper.release(seconds: 1)
        let back = await eventually { self.model.connection == .connected && self.agent.watchStarts == 2 }
        XCTAssertTrue(back, "l'app se reconnecte sans action de l'utilisateur")
        XCTAssertEqual(agent.watchCancels, 1, "l'ancien abonnement est libéré")
    }

    func testAgentGoneAfterAGoodSessionShowsReconnectingNotUnreachable() async {
        await connect()
        agent.setStatus(.failure(AgentClientError.unreachable))
        agent.endWatch()
        let state = await eventually { self.model.connection == .reconnecting(attempt: 1) }
        XCTAssertTrue(state)
        sleeper.release(seconds: 1)
        let second = await eventually { self.model.connection == .reconnecting(attempt: 2) }
        XCTAssertTrue(second)
    }

    func testIncompatibleVersionIsReportedAndRetriedSlowly() async {
        agent.setStatus(.failure(AgentClientError.agent(.versionMismatch(agent: 9, client: 1))))
        model.start()
        let shown = await eventually { self.model.connection == .versionMismatch(agent: 9) }
        XCTAssertTrue(shown)
        let slow = await eventually { self.sleeper.requests == [60] }
        XCTAssertTrue(slow, "pas de réessai rapide sur une version incompatible")
    }

    func testActionErrorIsShownAndBusyIsCleared() async {
        await connect()
        agent.setPerformError(AgentClientError.agent(.alreadyRunning))
        await model.runNow(id)
        XCTAssertEqual(model.alertMessage, AgentError.alreadyRunning.errorDescription)
        XCTAssertTrue(model.busyTasks.isEmpty)
    }

    func testActionsAreForwardedThenStateIsRefreshed() async {
        await connect()
        let before = agent.statusCalls
        await model.pause(id)
        await model.resume(id)
        await model.stop(id)
        await model.approve(id)
        await model.setGlobalPause(true)
        XCTAssertEqual(
            agent.performed,
            [.pause(id), .resume(id), .stop(id), .approveDeletion(id), .setGlobalPause(true)]
        )
        XCTAssertEqual(agent.statusCalls, before + 5)
        XCTAssertFalse(model.globalPauseBusy)
    }

    func testShutdownReleasesTheWatch() async {
        await connect()
        model.shutdown()
        let released = await eventually { self.agent.watchCancels == 1 }
        XCTAssertTrue(released)
    }

    func testRestartConnectsAgainRightAway() async {
        agent.setStatus(.failure(AgentClientError.unreachable))
        model.start()
        _ = await eventually { self.sleeper.requests.count == 1 }
        agent.setStatus(.success(makeStatus()))
        model.restart()
        let ok = await eventually { self.model.connection == .connected }
        XCTAssertTrue(ok)
    }

    func testHistoryErrorIsKept() async {
        agent.setHistory(.failure(AgentClientError.badReply))
        await connect()
        XCTAssertNotNil(model.historyError)
    }
}
