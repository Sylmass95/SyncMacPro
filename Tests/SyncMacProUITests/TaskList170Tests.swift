import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.7.0 : le tableau de bord devient une liste ordonnée de lignes.
@MainActor
final class TaskList170Tests: XCTestCase {
    let row = RowText(localizer: Localizer(language: "fr"))

    func info(_ name: String, _ state: TaskRunState, rank: Int? = 1, oneOff: Bool = false) -> AgentTaskInfo {
        var info = AgentTaskInfo(id: UUID(), name: name, state: state, isOneOff: oneOff)
        info.rank = rank
        return info
    }

    func testPlaceNames() {
        let home = NSHomeDirectory()
        XCTAssertEqual(row.place(.local(path: home + "/Desktop/PERSO-FILES"), drive: nil), "Bureau")
        XCTAssertEqual(row.place(.local(path: home + "/Documents/x"), drive: nil), "Documents")
        XCTAssertEqual(row.place(.network(url: "smb://admin@QNAPTS332X._smb._tcp.local/Documents", mountPath: "/Volumes/Documents/PERSO"), drive: nil),
                       "NAS « Documents »")
        XCTAssertEqual(row.place(.local(path: "/Volumes/HDDExtBRSM/BACKUP"), drive: nil), "Disque « HDDExtBRSM »")
        let drive = RemovableDrive(volumeUUID: "U", volumeName: "Extreme Pro", relativePath: "x", trigger: .everyConnection, resumeWindowDays: 3, eject: .never)
        XCTAssertEqual(row.place(.local(path: "/Volumes/Extreme Pro 1/x"), drive: drive), "Disque « Extreme Pro »")
        XCTAssertEqual(row.place(.cloud(remote: "Google Drive SyncMacPro rclone,team_drive=0AAAD", path: ""), drive: nil), "Drive partagé")
        XCTAssertEqual(row.place(.cloud(remote: "gdrive", path: "a"), drive: nil), "« gdrive »")
    }

    func testRowShowsRankPlacesStateAndWaitReason() {
        var waiting = info("Mac PERSO-PROJECT → QNAP", .queued, rank: 3)
        waiting.waitReason = "même disque que « Mac PERSO-FILES → QNAP »"
        XCTAssertEqual(row.rank(waiting), "3")
        XCTAssertEqual(row.state(waiting, text: UIFixtures.french), "En file — même disque que « Mac PERSO-FILES → QNAP »")
        var paused = info("A", .paused)
        paused.resumePending = true
        paused.waitReason = "en attente d'une place"
        XCTAssertEqual(row.state(paused, text: UIFixtures.french), "En pause, reprise en attente : en attente d'une place")
        let task = SyncTask(name: "t", source: .local(path: NSHomeDirectory() + "/Desktop/P"),
                            destination: .network(url: "smb://admin@qnap/Documents", mountPath: "/Volumes/Documents/P"))
        XCTAssertEqual(row.route(task), "Bureau → NAS « Documents »")
    }

    func testRowActionsByState() {
        XCTAssertEqual(TaskCard.availableActions(info: info("A", .idle), task: nil, driveMounted: nil), [.run, .force])
        XCTAssertEqual(TaskCard.availableActions(info: info("A", .queued), task: nil, driveMounted: nil), [.force, .stop])
        var pending = info("A", .paused)
        pending.resumePending = true
        XCTAssertEqual(TaskCard.availableActions(info: pending, task: nil, driveMounted: nil), [.force, .stop])
        XCTAssertEqual(TaskCard.availableActions(info: info("A", .paused), task: nil, driveMounted: nil), [.resume, .force, .stop])
        XCTAssertEqual(TaskCard.availableActions(info: info("A", .running), task: nil, driveMounted: nil), [.pause, .stop])
        XCTAssertEqual(TaskCard.availableActions(info: info("Copie", .queued, rank: nil, oneOff: true), task: nil, driveMounted: nil), [.force, .stop])
        XCTAssertEqual(TaskCard.availableActions(info: info("Copie", .idle, rank: nil, oneOff: true), task: nil, driveMounted: nil), [])
    }

    func testOneOffRowIsMarked() {
        XCTAssertEqual(row.rank(info("Copie", .queued, rank: nil, oneOff: true)), "•")
        XCTAssertTrue(row.badges(info("Copie", .queued, rank: nil, oneOff: true)).contains("ponctuelle"))
    }

    func testDisabledRowIsDimmed() {
        XCTAssertLessThan(TaskRow.opacity(for: info("A", .disabled)), 1)
        XCTAssertEqual(TaskRow.opacity(for: info("A", .idle)), 1)
    }

    func testListRendersInAgentOrder() {
        let infos = [info("C", .idle, rank: 1), info("A", .idle, rank: 2)]
        XCTAssertEqual(TaskListView.rowIDs(infos), infos.map(\.id) + [TaskListView.otherRunsID])
    }

    func testRowsRender() throws {
        let rows = VStack(spacing: 0) {
            ForEach(UIFixtures.infos) { info in
                TaskRow(info: info, task: UIFixtures.tasks.first { $0.id == info.id }, progress: nil, busy: false,
                        text: UIFixtures.french, actions: TaskCardActions())
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            assertNotBlank(try render(rows, name: "rows", size: CGSize(width: 1100, height: 400), scheme: scheme))
        }
    }
}
