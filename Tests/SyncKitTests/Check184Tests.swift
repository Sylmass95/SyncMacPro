import XCTest
@testable import SyncKit

/// 1.8.4 : essai réel du 25/10 — rclone relisait pendant 9 h une vidéo de 80 Go déjà sur le NAS (même taille, autre
/// date) pour la comparer ; la ligne semblait figée. On dit maintenant ce qu'il vérifie, et le comptage ne relit plus.
final class Check184Tests: XCTestCase {
    func testTheFileBeingCheckedIsRead() {
        let line = #"{"level":"notice","msg":"stats","stats":{"bytes":0,"checks":3,"checking":["EVENTS/VIDEOS/C2263.MP4"],"transfers":0}}"#
        guard case .stats(let stats) = RcloneOutputParser.parse(line: line) else { return XCTFail() }
        XCTAssertEqual(stats.checking, ["EVENTS/VIDEOS/C2263.MP4"])
    }

    func testTheSnapshotNamesTheCheckedFileAndItsSize() {
        let tracker = ProgressTracker(now: { Date(timeIntervalSince1970: 0) }, fileInfo: { name in (name == "C2263.MP4" ? 79_862_671_232 : 0, false) })
        tracker.start()
        tracker.apply(RcloneStats(bytes: 0, totalBytes: 0, speed: 0, eta: nil, transfers: 0, totalTransfers: 0, checks: 1, deletes: 0,
                                  errors: 0, elapsedTime: 1, fatalError: false, transferring: [], checking: ["C2263.MP4"]))
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.checkingName, "C2263.MP4")
        XCTAssertEqual(snap.checkingSize, 79_862_671_232)
        let info = ProgressInfo(snap)
        XCTAssertEqual(info.checkingName, "C2263.MP4")
        XCTAssertEqual(info.checkingSize, 79_862_671_232)
    }

    func testAnOlderAgentsProgressStillReads() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProgressInfo(TransferSnapshot()))) as? [String: Any])
        json.removeValue(forKey: "checkingName"); json.removeValue(forKey: "checkingSize")
        XCTAssertNil(try JSONDecoder().decode(ProgressInfo.self, from: JSONSerialization.data(withJSONObject: json)).checkingName)
    }

    func testTheCountingRunComparesSizesOnly() throws {
        let task = SyncTask(name: "t", source: .cloud(remote: "drive", path: "x"), destination: .local(path: "/Volumes/NAS/x"))
        let args = try RcloneCommandBuilder.countingCommand(for: task, run: RunOptions(archiveStamp: "s")).arguments
        XCTAssertTrue(args.contains("--size-only"), "le comptage ne relit pas les fichiers déjà présents")
        XCTAssertTrue(args.contains("--dry-run"))
    }
}
