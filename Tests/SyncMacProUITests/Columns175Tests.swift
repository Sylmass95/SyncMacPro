import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

/// 1.7.5 : colonnes redimensionnables (largeurs retenues) et temps restant lisible au-delà d'un jour.
@MainActor
final class Columns175Tests: XCTestCase {
    func store() -> UserDefaults {
        let name = "colonnes-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testAColumnIsResizedWithinItsLimits() {
        var columns = ListColumns()
        let start = columns.width(.state)
        columns.resize(.state, by: 60)
        XCTAssertEqual(columns.width(.state), start + 60)
        columns.resize(.state, by: -10_000)
        XCTAssertEqual(columns.width(.state), ListColumn.state.minimum)
        columns.resize(.state, by: 10_000)
        XCTAssertEqual(columns.width(.state), ListColumn.state.maximum)
        columns.reset(.state)
        XCTAssertEqual(columns.width(.state), ListColumn.state.standard)
    }

    func testWidthsAreRemembered() {
        let defaults = store()
        var columns = ListColumns()
        columns.resize(.schedule, by: 40)
        columns.save(to: defaults)
        XCTAssertEqual(ListColumns(from: defaults).width(.schedule), ListColumn.schedule.standard + 40)
        XCTAssertEqual(ListColumns(from: defaults).width(.last), ListColumn.last.standard)
    }

    func testTheTaskColumnIsNotResizable() {
        XCTAssertFalse(ListColumn.allCases.contains(.task) && ListColumn.task.resizable)
    }

    func testLongRemainingTimesUseDays() {
        XCTAssertEqual(Localizer(language: "fr").duration(163_958), "1 j 21 h 32")
        XCTAssertEqual(Localizer(language: "en").duration(163_958), "1 d 21 h 32")
        XCTAssertEqual(Localizer(language: "fr").duration(3725), "1:02:05", "moins d'un jour : inchangé")
    }

    /// Rendu d'un en-tête et d'une copie longue : rien ne doit être coupé (image dans syncmacpro-renders).
    func testHeaderAndALongCopyRender() throws {
        var info = AgentTaskInfo(id: UUID(), name: "NAS 01_PROJETS_ACTIFS → Drive", state: .running)
        info.rank = 8
        var p = ProgressInfo(TransferSnapshot())
        p.doneBytes = 154_157_000_000; p.totalBytes = 734_000_000_000; p.currentSpeed = 6_291_456; p.totalETA = 163_958
        p.overallPercent = 21; p.currentName = "EVENTS/2024-BR DAY/RUSHS/CAM A/BR DAY_241009_DJ0C.MOV"
        let view = VStack(spacing: 0) {
            TaskListHeader(columns: .constant(ListColumns()), localizer: UIFixtures.french.localizer, onChange: {})
            TaskRow(info: info, task: SyncTask(name: info.name, source: .network(url: "smb://moi@nas/01_PROJETS_ACTIFS", mountPath: "/Volumes/01_PROJETS_ACTIFS"),
                                               destination: .cloud(remote: "Drive,team_drive=X", path: "BACKUP"), schedule: .daily(hour: 3, minute: 0)),
                    progress: p, busy: false, text: UIFixtures.french, actions: TaskCardActions()).padding(.horizontal, 16)
        }
        assertNotBlank(try render(view, name: "liste-175", size: CGSize(width: 900, height: 160), scheme: .light))
    }
}
