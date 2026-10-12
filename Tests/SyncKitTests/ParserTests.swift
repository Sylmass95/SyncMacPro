import XCTest
@testable import SyncKit

final class LineSplitterTests: XCTestCase {
    func testSplitsOnNewlineAndCarriageReturn() {
        XCTAssertEqual(LineSplitter.lines(in: "a\nb\r  c  \r\n\n"), ["a", "b", "c"])
    }

    func testKeepsPartialLineAcrossChunks() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed("hel"), [])
        XCTAssertEqual(splitter.feed("lo\nwor"), ["hello"])
        XCTAssertEqual(splitter.feed("ld"), [])
        XCTAssertEqual(splitter.finish(), ["world"])
        XCTAssertEqual(splitter.finish(), [])
    }
}

final class RsyncOutputParserTests: XCTestCase {
    func testRealProgressCapture() throws {
        let events = LineSplitter.lines(in: try Fixture.text("rsync_progress")).compactMap(RsyncOutputParser.parse(line:))

        XCTAssertTrue(events.contains(.message("sending incremental file list")))
        XCTAssertTrue(events.contains(.fileStarted(name: "a.txt", isNew: nil)))
        XCTAssertTrue(events.contains(.fileStarted(name: "big.bin", isNew: nil)))
        XCTAssertTrue(events.contains(.directory(name: "sub/")))
        XCTAssertTrue(events.contains(.fileStarted(name: "sub/mid.bin", isNew: nil)))
        // « ./ » est ignoré
        XCTAssertFalse(events.contains(.directory(name: "./")))

        // première ligne de progression de big.bin : 32 768 octets, 0 %, 31,25 Mo/s
        XCTAssertTrue(events.contains(.progress(bytes: 32_768, percent: 0, bytesPerSecond: 31.25 * 1_048_576, fileFinished: false)))
        // dernière ligne du fichier : 30 000 000 octets, 100 %, marquée terminée
        let finished = events.compactMap { event -> Int64? in
            if case .progress(let bytes, 100, _, true) = event { return bytes }
            return nil
        }
        XCTAssertEqual(finished, [6, 30_000_000, 2_000_000])
    }

    func testItemizedRealCapture() throws {
        let events = LineSplitter.lines(in: try Fixture.text("rsync_progress_itemized")).compactMap(RsyncOutputParser.parse(line:))

        XCTAssertTrue(events.contains(.deleting(name: "gone.txt")))
        XCTAssertTrue(events.contains(.fileStarted(name: "new.bin", isNew: true)))
        XCTAssertTrue(events.contains(.fileStarted(name: "sub/deep.txt", isNew: true)))
        XCTAssertTrue(events.contains(.fileStarted(name: "upd.txt", isNew: false)))      // « >f.st...... » : mise à jour
        XCTAssertTrue(events.contains(.fileStarted(name: "timeonly.txt", isNew: false)))
        XCTAssertTrue(events.contains(.directory(name: "sub/")))
        XCTAssertFalse(events.contains { if case .fileStarted(let name, _) = $0 { return name.contains("|") } else { return false } })
    }

    func testItemizedLinesThatMoveNoDataAreIgnored() {
        XCTAssertNil(RsyncOutputParser.parse(line: ".f..t......|only-a-date.txt"))
        XCTAssertNil(RsyncOutputParser.parse(line: "cL+++++++++|a-symlink"))
        XCTAssertEqual(RsyncOutputParser.parse(line: ".d..t......|sub/"), .directory(name: "sub/"))
        XCTAssertNil(RsyncOutputParser.parse(line: ".d..t......|./"))
    }

    func testItemizedNameMayContainABar() {
        XCTAssertEqual(RsyncOutputParser.parse(line: ">f+++++++++|a|b.txt"), .fileStarted(name: "a|b.txt", isNew: true))
    }

    func testSpeedUnits() {
        XCTAssertEqual(
            RsyncOutputParser.parse(line: "1,234  50%   94.96kB/s    0:00:20"),
            .progress(bytes: 1234, percent: 50, bytesPerSecond: 94.96 * 1024, fileFinished: false)
        )
    }

    func testDeletionsAndErrors() {
        XCTAssertEqual(RsyncOutputParser.parse(line: "deleting old.txt"), .deleting(name: "old.txt"))
        let lines = [
            "rsync: [receiver] write failed on \"x\": Broken pipe (32)",
            "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338)",
            "rsync(90432): error: buf_copy",
        ]
        for line in lines {
            XCTAssertEqual(RsyncOutputParser.parse(line: line), .error(line))
        }
    }

    func testIgnoresBlankAndRootFolder() {
        XCTAssertNil(RsyncOutputParser.parse(line: ""))
        XCTAssertNil(RsyncOutputParser.parse(line: "./"))
    }

    func testFileNamesWithSpacesAndUnicode() {
        XCTAssertEqual(RsyncOutputParser.parse(line: "Rushes été/clip n°1 (copie).mov"),
                       .fileStarted(name: "Rushes été/clip n°1 (copie).mov", isNew: nil))
    }
}

final class RsyncPlanParserTests: XCTestCase {
    func testCopyPlan() throws {
        let plan = RsyncPlanParser.parse(try Fixture.text("rsync_plan_copy"))
        XCTAssertEqual(plan.files, ["a.txt": 6, "big.bin": 30_000_000, "sub/mid.bin": 2_000_000])
        XCTAssertEqual(plan.directories, ["sub/"])
        XCTAssertEqual(plan.totalBytes, 32_000_006)
        XCTAssertEqual(plan.sourceRegularFiles, 3)
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testMirrorPlanListsDeletions() throws {
        let plan = RsyncPlanParser.parse(try Fixture.text("rsync_plan_mirror"))
        XCTAssertEqual(Set(plan.deletions), ["old1.txt", "old2.txt"])
        XCTAssertEqual(plan.files, ["new.txt": 4])
        XCTAssertEqual(plan.sourceRegularFiles, 2)
    }

    func testEmptyTextGivesEmptyPlan() {
        XCTAssertEqual(RsyncPlanParser.parse(""), RsyncPlan())
    }
}

final class VerifyParserTests: XCTestCase {
    func testRsyncDifferences() throws {
        let names = VerifyParser.rsyncDifferences(in: try Fixture.text("rsync_verify"))
        XCTAssertEqual(Set(names), ["changed.txt", "fresh.txt"])
    }

    func testRsyncIgnoresDirectoryOnlyLines() {
        XCTAssertEqual(VerifyParser.rsyncDifferences(in: ".d..t......|./\n>fc.T......|a.txt"), ["a.txt"])
    }

    func testRcloneDifferences() throws {
        let names = VerifyParser.rcloneDifferences(in: try Fixture.text("rclone_check"))
        XCTAssertEqual(Set(names), ["b.txt", "c.txt", "d.txt"])
    }

    /// Après une copie, des fichiers « en plus » à la destination (lignes « - ») sont normaux.
    func testRcloneDifferencesCanIgnoreFilesThatOnlyExistOnTheDestination() throws {
        let names = VerifyParser.rcloneDifferences(in: try Fixture.text("rclone_check"), includeMissingOnSource: false)
        XCTAssertEqual(Set(names), ["b.txt", "c.txt"])
    }
}

final class RcloneOutputParserTests: XCTestCase {
    private func events(_ fixture: String) throws -> [RcloneEvent] {
        try Fixture.text(fixture, ext: "jsonl").split(separator: "\n").compactMap { RcloneOutputParser.parse(line: String($0)) }
    }

    func testRealCopyCapture() throws {
        let all = try events("rclone_copy")
        let stats = all.compactMap { event -> RcloneStats? in
            if case .stats(let value) = event { return value }
            return nil
        }
        XCTAssertFalse(stats.isEmpty)

        let inFlight = try XCTUnwrap(stats.first { !$0.transferring.isEmpty })
        XCTAssertEqual(inFlight.transferring.first?.name, "big.bin")
        XCTAssertEqual(inFlight.transferring.first?.size, 30_000_000)
        XCTAssertEqual(inFlight.totalBytes, 32_000_006)

        let final = try XCTUnwrap(stats.last)
        XCTAssertEqual(final.bytes, 32_000_006)
        XCTAssertEqual(final.transfers, 3)
        XCTAssertEqual(final.totalTransfers, 3)
        XCTAssertEqual(final.errors, 0)
        XCTAssertTrue(final.transferring.isEmpty)
    }

    func testDryRunMirrorReportsDeletes() throws {
        let all = try events("rclone_sync_dryrun")
        XCTAssertTrue(all.contains(.notice(message: "Skipped delete as --dry-run is set (size 3)", object: "e1.txt")))
        let deletes = all.compactMap { event -> Int? in
            if case .stats(let value) = event { return value.deletes }
            return nil
        }
        XCTAssertEqual(deletes.last, 2)
    }

    func testIgnoresNonJSONAndErrorsAreReported() {
        XCTAssertNil(RcloneOutputParser.parse(line: "2026/10/12 16:48:19 NOTICE: hello"))
        let line = #"{"level":"error","msg":"Failed to copy: boom","source":"x"}"#
        XCTAssertEqual(RcloneOutputParser.parse(line: line), .error("Failed to copy: boom"))
    }
}

final class OutputSignalTests: XCTestCase {
    func testDetectsRealMessages() {
        XCTAssertEqual(OutputSignal.detect(in: #"Safety abort: too many deletes (>40%, 5 of 10) on Path1 "g1/". Run with --force if desired."#), .safetyAbort)
        XCTAssertEqual(OutputSignal.detect(in: "Bisync aborted. Must run --resync to recover."), .needsResync)
        XCTAssertEqual(OutputSignal.detect(in: "max transfer limit reached as set by --max-transfer - stopping transfers"), .quotaReached)
        XCTAssertNil(OutputSignal.detect(in: "everything is fine"))
    }
}
