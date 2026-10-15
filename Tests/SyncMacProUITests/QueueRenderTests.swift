import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

@MainActor
final class QueueRenderTests: XCTestCase {
    func model() -> (AgentModel, UUID, UUID) {
        let a = UUID(), b = UUID()
        var progress = ProgressInfo(TransferSnapshot())
        progress.filesDone = 120; progress.totalFiles = 925; progress.dirsDone = 14; progress.totalDirs = 136
        progress.doneBytes = 14_000_000_000; progress.totalBytes = 59_800_000_000; progress.averageSpeed = 25_300_000
        progress.activeTime = 724; progress.currentName = "MULTI-DEVICES/visuel.tif"; progress.overallPercent = 23
        let status = AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [
            AgentTaskInfo(id: a, name: "COMMONS 05 Visuels → NAS", state: .running, progress: progress),
            AgentTaskInfo(id: b, name: "COMMONS 01 Charte → NAS", state: .idle, queuePosition: 1),
        ], queue: QueueInfo(running: true, items: [b], current: a))
        let manual = SyncTask(id: b, name: "COMMONS 01 Charte → NAS", source: .cloud(remote: "Drive", path: "x"),
                              destination: .cloud(remote: "nas", path: "y"), schedule: .manual)
        return (AgentModel.preview(status: status, tasks: [manual], progress: [a: progress]), a, b)
    }

    func testQueueSectionAndCardsRender() throws {
        let (model, _, _) = model()
        XCTAssertEqual(model.queue?.items.count, 1)
        let l = Localizer(language: "fr")
        for scheme in [ColorScheme.light, .dark] {
            _ = try render(QueueSection(model: model, localizer: l).glassThemed(), name: "file", size: CGSize(width: 440, height: 200), scheme: scheme)
            _ = try render(DashboardBody(model: model, installState: .enabled, text: CardText(localizer: l), onInstall: {}).glassThemed(),
                           name: "tableau-file", size: CGSize(width: 1100, height: 760), scheme: scheme)
        }
    }

    func testCardDetailsUseTheRsyncGUILines() {
        let (model, a, _) = model()
        let lines = TaskProgressDetails.lines(model.progress[a]!, presentation: ProgressPresentation(localizer: Localizer(language: "fr")))
        XCTAssertTrue(lines.contains("Fichiers 120 / 925"))
        XCTAssertTrue(lines.contains("Dossiers 14 / 136"))
        XCTAssertTrue(lines.contains("Écoulé 12 min 04 s"))
        XCTAssertTrue(lines.contains { $0.hasSuffix("en moyenne") })
    }
}
