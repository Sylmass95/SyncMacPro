import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.7.0 : la liste ordonnée côté app — déplacer, forcer, historique d'une tâche.
@MainActor
final class ListModel170Tests: XCTestCase {
    func info(_ id: UUID, _ name: String, rank: Int?, oneOff: Bool = false) -> AgentTaskInfo {
        var info = AgentTaskInfo(id: id, name: name, state: .idle, isOneOff: oneOff)
        info.rank = rank
        return info
    }

    func model(with infos: [AgentTaskInfo]) async -> (AgentModel, FakeAgent) {
        let agent = FakeAgent()
        agent.setStatus(.success(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: infos)))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.refreshNow()
        return (model, agent)
    }

    func testMovingTwoSelectedTasksSendsTheFullOrder() async {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let (model, agent) = await model(with: [info(a, "A", rank: 1), info(b, "B", rank: 2), info(c, "C", rank: 3), info(d, "D", rank: 4)])
        await model.move([c, d], toOffset: 0)
        XCTAssertEqual(agent.performed.first, .reorder([c, d, a, b]))
        model.shutdown()
    }

    func testMovingDownwardsUsesTheOffsetBeforeRemoval() async {
        let a = UUID(), b = UUID(), c = UUID()
        let (model, agent) = await model(with: [info(a, "A", rank: 1), info(b, "B", rank: 2), info(c, "C", rank: 3)])
        await model.move([a], toOffset: 3)   // comme `onMove` : sous la dernière ligne
        XCTAssertEqual(agent.performed.first, .reorder([b, c, a]))
        model.shutdown()
    }

    func testMoveKeepsOneOffsOutOfTheOrder() async {
        let once = UUID(), a = UUID(), b = UUID()
        let (model, agent) = await model(with: [info(once, "Ponctuelle", rank: nil, oneOff: true), info(a, "A", rank: 1), info(b, "B", rank: 2)])
        await model.move([b], toOffset: 1)   // index dans la liste affichée (ponctuelle comprise)
        XCTAssertEqual(agent.performed.first, .reorder([b, a]))
        model.shutdown()
    }

    func testForceSendsForce() async {
        let a = UUID()
        let (model, agent) = await model(with: [info(a, "A", rank: 1)])
        await model.force(a)
        XCTAssertEqual(agent.performed, [.force(a)])
        model.shutdown()
    }

    func testHistoryForATaskAsksTheAgentForThatTask() async {
        let a = UUID()
        let (model, agent) = await model(with: [info(a, "A", rank: 1)])
        agent.setHistory(.success([RunRecord(taskID: a, taskName: "A", engine: .rsync, mode: .copy, startedAt: Date()),
                                   RunRecord(taskID: UUID(), taskName: "B", engine: .rsync, mode: .copy, startedAt: Date())]))
        let records = await model.taskHistory(for: a)
        XCTAssertEqual(records.map(\.taskName), ["A"])
        XCTAssertEqual(agent.historyRequests.last?.taskID, a)
        XCTAssertEqual(agent.historyRequests.last?.limit, 200)
        model.shutdown()
    }

    func testOtherRunsAreThoseOfUnknownTasks() async {
        let a = UUID()
        let (model, agent) = await model(with: [info(a, "A", rank: 1)])
        agent.setTasks([SyncTask(id: a, name: "A", source: .local(path: "/a"), destination: .local(path: "/b"))])
        await model.refreshNow()
        agent.setHistory(.success([RunRecord(taskID: a, taskName: "A", engine: .rsync, mode: .copy, startedAt: Date()),
                                   RunRecord(taskID: UUID(), taskName: "Ponctuelle", engine: .rsync, mode: .copy, startedAt: Date())]))
        let records = await model.taskHistory(for: nil)
        XCTAssertEqual(records.map(\.taskName), ["Ponctuelle"])
        model.shutdown()
    }

    /// 1.7.0 : « Forcer » de l'écran Copier : la copie ponctuelle part tout de suite.
    func testCopyForceStartsTheOneOffAtOnce() async {
        let (model, agent) = await model(with: [])
        let copy = SyncTask(name: "Copie", source: .local(path: "/a"), destination: .local(path: "/b"))
        _ = await model.runOnce([copy], force: true)
        XCTAssertEqual(agent.performed, [.runOnce(copy), .force(copy.id)])
        model.shutdown()
    }
}
