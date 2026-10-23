import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.3 : on voit d'où vient chaque fichier et où il va, et son chemin complet.
@MainActor
final class Details183UITests: XCTestCase {
    let l = UIFixtures.french.localizer
    let bts = SyncTask(name: "BTS · Drive ⇄ NAS", source: .cloud(remote: "Drive,team_drive=X", path: ""),
                       destination: .network(url: "smb://moi@10.92.7.3/01_PROJETS_ACTIFS", mountPath: "/Volumes/01_PROJETS_ACTIFS/BEHIND_THE_STREAMS"),
                       mode: .bidirectional)

    func testWhereABisyncFileCameFrom() {
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .updated, size: 1, path: "a", origin: .local), task: bts, localizer: l),
                       "NAS « 01_PROJETS_ACTIFS » → Drive partagé")
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .added, size: 1, path: "a", origin: .cloud), task: bts, localizer: l),
                       "Drive partagé → NAS « 01_PROJETS_ACTIFS »")
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .archived, size: 1, path: "a", origin: .cloud), task: bts, localizer: l),
                       "sur Drive partagé")
    }

    func testWhereARsyncFileWent() {
        let copy = SyncTask(name: "c", source: .local(path: NSHomeDirectory() + "/Desktop/PERSO-FILES"),
                            destination: .network(url: "smb://admin@q/Documents", mountPath: "/Volumes/Documents/PERSO-FILES"))
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .added, size: 1, path: "a", origin: .source), task: copy, localizer: l),
                       "Bureau → NAS « Documents »")
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .deleted, size: nil, path: "a", origin: .destination), task: copy, localizer: l),
                       "sur NAS « Documents »")
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .added, size: 1, path: "a"), task: copy, localizer: l), "", "provenance inconnue (1.8.2)")
        XCTAssertEqual(RunDetailsView.whereText(RunDetailRow(action: .added, size: 1, path: "a", origin: .source), task: nil, localizer: l), "")
    }

    func testTheFullPathOfAFileOnTheDisk() {
        XCTAssertEqual(RunDetailsView.fullPath(RunDetailRow(action: .updated, size: 1, path: "2026/x.mp4", origin: .local), task: bts),
                       "/Volumes/01_PROJETS_ACTIFS/BEHIND_THE_STREAMS/2026/x.mp4")
        XCTAssertNil(RunDetailsView.fullPath(RunDetailRow(action: .updated, size: 1, path: "x", origin: .cloud), task: bts), "en ligne : pas de chemin sur le Mac")
    }

    func testDetailsOpenInTheirOwnWindow() {
        let record = RunRecord(taskID: bts.id, taskName: bts.name, engine: .rclone, mode: .bidirectional, startedAt: Date(timeIntervalSince1970: 0), status: .succeeded)
        let target = RunDetailsTarget(record: record)
        XCTAssertEqual(target.runID, record.id)
        XCTAssertEqual(target.taskID, bts.id)
        XCTAssertEqual(try JSONDecoder().decode(RunDetailsTarget.self, from: JSONEncoder().encode(target)), target)
    }
}
