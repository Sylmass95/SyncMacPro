import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class QueueModelTests: XCTestCase {
    func testBandwidthIsSentOnceTheUserStopsTyping() async {
        let agent = FakeAgent()
        let sleeper = ManualSleeper()
        let model = AgentModel(agent: agent, sleeper: sleeper)
        model.setBandwidth(BandwidthLimits(downloadMbps: 1))
        model.setBandwidth(BandwidthLimits(downloadMbps: 12))
        model.setBandwidth(BandwidthLimits(downloadMbps: 120))
        XCTAssertEqual(model.bandwidth?.downloadMbps, 120, "affiché tout de suite")
        _ = await eventually { sleeper.requests.count >= 3 }
        sleeper.release(seconds: 0.6)
        let sent = await eventually { agent.performed == [.setBandwidth(BandwidthLimits(downloadMbps: 120))] }
        XCTAssertTrue(sent, "\(agent.performed)")
        model.shutdown()
    }
}

final class ProgressPresentationTests: XCTestCase {
    let p = ProgressPresentation(localizer: Localizer(language: "fr"))

    func testLines() {
        XCTAssertEqual(p.filesLine(done: 120, total: 925), "Fichiers 120 / 925")
        XCTAssertEqual(p.dirsLine(done: 14, total: 136), "Dossiers 14 / 136")
        XCTAssertNil(p.dirsLine(done: 0, total: nil))
        XCTAssertEqual(p.elapsedLine(724), "Écoulé 12 min 04 s")
        XCTAssertEqual(p.elapsedLine(3_780), "Écoulé 1 h 03 min")
        XCTAssertEqual(p.averageSpeedLine(26_214_400), "25,0 Mo/s en moyenne")
        XCTAssertNil(p.averageSpeedLine(nil))
    }

    func testSummaryLines() {
        let summary = RunSummary(filesTransferred: 925, bytesTransferred: 1_048_576, durationSeconds: 65,
                                 directories: 136, averageSpeed: 1_048_576)
        XCTAssertEqual(p.summaryLines(summary), ["925 fichier(s)", "1,0 Mo", "136 dossier(s)", "1,0 Mo/s en moyenne", "Écoulé 1 min 05 s"])
    }

    func testManualTasksHaveNoNextRunLine() {
        let text = CardText(localizer: Localizer(language: "fr"))
        var manual = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        manual.schedule = .manual
        XCTAssertNil(text.nextRunLine(info: AgentTaskInfo(id: manual.id, name: "t", state: .idle), task: manual))
        var nightly = manual
        nightly.schedule = .daily(hour: 3, minute: 0)
        XCTAssertNotNil(text.nextRunLine(info: AgentTaskInfo(id: manual.id, name: "t", state: .idle, nextDue: Date()), task: nightly))
    }
}
