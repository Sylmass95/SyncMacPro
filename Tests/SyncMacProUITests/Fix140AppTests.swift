import XCTest
import AppKit
import SyncKit
@testable import SyncMacProUI

/// Corrections mineures de la 1.3.0, côté app.
@MainActor
final class Fix140AppTests: XCTestCase {
    func testQueuedOneOffHasNoRunButton() {
        let queued = AgentTaskInfo(id: UUID(), name: "Copie", state: .queued, isOneOff: true)
        XCTAssertFalse(TaskCard.availableActions(info: queued, task: nil, driveMounted: nil).contains(.run))
        let idleCopy = AgentTaskInfo(id: UUID(), name: "Copie", state: .idle, isOneOff: true)
        XCTAssertFalse(TaskCard.availableActions(info: idleCopy, task: nil, driveMounted: nil).contains(.run))
        let task = AgentTaskInfo(id: UUID(), name: "Tâche", state: .idle)
        XCTAssertEqual(TaskCard.availableActions(info: task, task: nil, driveMounted: nil), [.run, .force])   // 1.7.0
    }

    func testFinishedOneOffSummaryIsKeptUntilDismissed() async {
        let agent = FakeAgent()
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let copy = AgentTaskInfo(id: UUID(), name: "Copie de 2 élément(s)", state: .running, isOneOff: true)
        agent.setStatus(.success(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [copy])))
        await model.refreshNow()
        agent.setStatus(.success(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [])))
        await model.refreshNow()
        XCTAssertEqual(model.finishedCopies.map(\.id), [copy.id])
        XCTAssertEqual(model.finishedCopies.first?.state, .idle)
        model.dismissFinishedCopy(copy.id)
        XCTAssertTrue(model.finishedCopies.isEmpty)
        model.shutdown()
    }

    func testDraftIsSentOnlyWhenTheUserChangedIt() {
        let limits = BandwidthLimits(downloadMbps: 200)
        XCTAssertNil(NetworkSettingsSection.limitsToSend(draft: BandwidthDraft(limits), current: limits), "lecture initiale : rien à envoyer")
        var draft = BandwidthDraft(limits)
        draft.downloadText = "300"
        XCTAssertEqual(NetworkSettingsSection.limitsToSend(draft: draft, current: limits), BandwidthLimits(downloadMbps: 300))
    }

    func testClosingThePanelShowsTheMainWindow() {
        let controller = MiniPanelController()
        var restored = 0
        controller.onRestore = { restored += 1 }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(restored, 1)
    }
}
