import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

@MainActor
final class MiniViewTests: XCTestCase {
    func testMiniShowsRunningTransfersAndTheQueue() throws {
        let running = UUID(), queued = UUID()
        var progress = ProgressInfo(TransferSnapshot())
        progress.currentName = "MULTI-DEVICES/visuel.tif"; progress.filesDone = 10; progress.totalFiles = 925
        progress.doneBytes = 3_000_000_000; progress.totalBytes = 59_800_000_000; progress.currentSpeed = 25_000_000
        progress.overallPercent = 5; progress.activeTime = 130
        let status = AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [
            AgentTaskInfo(id: running, name: "COMMONS 05", state: .running, progress: progress),
            AgentTaskInfo(id: queued, name: "COMMONS 01", state: .queued),
        ])
        let model = AgentModel.preview(status: status, progress: [running: progress])
        XCTAssertEqual(MiniView.runningIDs(model.status), [running])
        let view = MiniView(model: model, localizer: Localizer(language: "fr"), onExpand: {})
        for scheme in [ColorScheme.light, .dark] {
            _ = try render(MiniBody(model: model, localizer: Localizer(language: "fr"), onExpand: {}).glassThemed(),
                           name: "miniature", size: CGSize(width: 380, height: 420), scheme: scheme)
        }
        _ = view
    }

    /// 1.7.0 : copies en cours, puis les trois prochaines dans l'ordre de la liste.
    func testMiniShowsRunningThenNextInOrder() {
        let ids = (0..<5).map { _ in UUID() }
        var pending = AgentTaskInfo(id: ids[4], name: "E", state: .paused)
        pending.resumePending = true
        let status = AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [
            AgentTaskInfo(id: ids[0], name: "A", state: .queued),
            AgentTaskInfo(id: ids[1], name: "B", state: .running),
            AgentTaskInfo(id: ids[2], name: "C", state: .idle),
            AgentTaskInfo(id: ids[3], name: "D", state: .queued),
            pending,
        ])
        XCTAssertEqual(MiniView.runningIDs(status), [ids[1]])
        XCTAssertEqual(MiniView.nextIDs(status), [ids[0], ids[3], ids[4]])
    }

    func testNothingRunningShowsAnEmptyState() {
        XCTAssertEqual(MiniView.runningIDs(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [])), [])
        XCTAssertEqual(MiniView.runningIDs(nil), [])
    }
}
