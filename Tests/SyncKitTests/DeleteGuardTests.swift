import XCTest
@testable import SyncKit

final class DeleteGuardTests: XCTestCase {
    func testThresholdIsInclusive() {
        XCTAssertEqual(DeleteGuard.verdict(deletions: 3, existing: 12, thresholdPercent: 25), .allowed)       // 25 %
        XCTAssertEqual(DeleteGuard.verdict(deletions: 4, existing: 12, thresholdPercent: 25),
                       .blocked(percent: 33, deletions: 4, existing: 12))
    }

    func testNoDeletionsIsAlwaysAllowed() {
        XCTAssertEqual(DeleteGuard.verdict(deletions: 0, existing: 0, thresholdPercent: 0), .allowed)
        XCTAssertEqual(DeleteGuard.verdict(deletions: 0, existing: 500, thresholdPercent: 0), .allowed)
    }

    func testDeletingEverythingIsBlockedEvenWithNothingKnown() {
        XCTAssertEqual(DeleteGuard.verdict(deletions: 5, existing: 0, thresholdPercent: 25),
                       .blocked(percent: 100, deletions: 5, existing: 0))
    }

    func testRsyncMirrorPlanFromRealCapture() throws {
        // La destination avait 3 fichiers (keep, old1, old2) ; la source en a 2 (keep, new) : 2 suppressions sur 3.
        let plan = RsyncPlanParser.parse(try Fixture.text("rsync_plan_mirror"))
        XCTAssertEqual(plan.createdRegularFiles, 1)
        XCTAssertEqual(DeleteGuard.verdict(for: plan, thresholdPercent: 25), .blocked(percent: 66, deletions: 2, existing: 3))
        XCTAssertEqual(DeleteGuard.verdict(for: plan, thresholdPercent: 70), .allowed)
    }

    func testEmptiedSourceCannotWipeTheDestination() {
        var plan = RsyncPlan()
        plan.deletions = ["a", "b", "c", "d"]
        plan.sourceRegularFiles = 0
        plan.createdRegularFiles = 0
        XCTAssertEqual(DeleteGuard.verdict(for: plan, thresholdPercent: 25), .blocked(percent: 100, deletions: 4, existing: 4))
    }

    func testMaxDeleteCount() {
        XCTAssertEqual(DeleteGuard.maxDeleteCount(existing: 200, thresholdPercent: 25), 50)
        XCTAssertEqual(DeleteGuard.maxDeleteCount(existing: 3, thresholdPercent: 25), 0)
    }

    func testRcloneSizeParsing() {
        XCTAssertEqual(RcloneSizeParser.count(from: #"{"count":3,"bytes":8,"sizeless":0}"# + "\n"), 3)
        XCTAssertNil(RcloneSizeParser.count(from: "not json"))
    }

    func testRcloneDryRunMirrorFromRealCapture() throws {
        let events = try Fixture.text("rclone_sync_dryrun", ext: "jsonl").split(separator: "\n")
            .compactMap { RcloneOutputParser.parse(line: String($0)) }
        let deletes = events.compactMap { event -> Int? in
            if case .stats(let stats) = event { return stats.deletes }
            return nil
        }.last
        // la destination avait 3 fichiers (k, e1, e2) et 2 seraient supprimés
        XCTAssertEqual(DeleteGuard.verdict(deletions: try XCTUnwrap(deletes), existing: 3, thresholdPercent: 25),
                       .blocked(percent: 66, deletions: 2, existing: 3))
    }
}
