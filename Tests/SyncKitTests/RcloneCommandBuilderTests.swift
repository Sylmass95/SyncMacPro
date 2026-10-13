import XCTest
@testable import SyncKit

final class RcloneCommandBuilderTests: XCTestCase {
    private let run = RunOptions(archiveStamp: "2026-10-12_14-30")

    private func task(
        mode: SyncMode = .copy,
        items: [String] = [],
        options: TaskOptions = TaskOptions(excludes: [])
    ) -> SyncTask {
        SyncTask(
            name: "t",
            source: .network(url: "smb://nas/s", mountPath: "/Volumes/s"),
            destination: .cloud(remote: "gdrive", path: "BACKUP"),
            sourceItems: items, mode: mode, options: options
        )
    }

    func testCopyBuildsVerbAndPaths() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(), run: run)
        XCTAssertEqual(cmd.engine, .rclone)
        XCTAssertEqual(Array(cmd.arguments.prefix(3)), ["copy", "/Volumes/s", "gdrive:BACKUP"])
        XCTAssertTrue(cmd.arguments.contains("--use-json-log"))
        XCTAssertFalse(cmd.arguments.contains("--dry-run"))
    }

    func testMirrorUsesArchiveOnTheDestinationRemote() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .mirror), run: run)
        XCTAssertEqual(cmd.arguments.first, "sync")
        let idx = try XCTUnwrap(cmd.arguments.firstIndex(of: "--backup-dir"))
        XCTAssertEqual(cmd.arguments[idx + 1], "gdrive:BACKUP/_ARCHIVE/2026-10-12_14-30")
        XCTAssertTrue(cmd.arguments.contains("/_ARCHIVE/**"))
    }

    func testMirrorPassesMaxDeleteCountWhenKnown() throws {
        var limited = run
        limited.maxDeleteCount = 12
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .mirror), run: limited)
        let idx = try XCTUnwrap(cmd.arguments.firstIndex(of: "--max-delete"))
        XCTAssertEqual(cmd.arguments[idx + 1], "12")
    }

    func testBidirectionalGuardsAndArchivesBothSides() throws {
        var first = run
        first.resync = true
        first.bisyncWorkdir = "/tmp/bisync/abc"
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .bidirectional), run: first)
        XCTAssertEqual(Array(cmd.arguments.prefix(3)), ["bisync", "/Volumes/s", "gdrive:BACKUP"])
        for flag in ["--resilient", "--recover", "--resync"] {
            XCTAssertTrue(cmd.arguments.contains(flag), flag)
        }
        func value(after flag: String) -> String? {
            cmd.arguments.firstIndex(of: flag).map { cmd.arguments[$0 + 1] }
        }
        XCTAssertEqual(value(after: "--max-delete"), "25")      // pourcentage pour bisync
        XCTAssertEqual(value(after: "--conflict-resolve"), "newer")
        XCTAssertEqual(value(after: "--backup-dir1"), "/Volumes/s/_ARCHIVE/2026-10-12_14-30")
        XCTAssertEqual(value(after: "--backup-dir2"), "gdrive:BACKUP/_ARCHIVE/2026-10-12_14-30")
        XCTAssertEqual(value(after: "--workdir"), "/tmp/bisync/abc")
        XCTAssertEqual(value(after: "--resync-mode"), "newer", "une resynchronisation garde la version la plus récente")
    }

    func testBidirectionalWithoutResyncOmitsTheFlag() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .bidirectional), run: run)
        XCTAssertFalse(cmd.arguments.contains("--resync"))
    }

    func testMoveRemovesEmptySourceFolders() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .move), run: run)
        XCTAssertEqual(cmd.arguments.first, "move")
        XCTAssertTrue(cmd.arguments.contains("--delete-empty-src-dirs"))
    }

    func testVerifyUsesCheckWithCombinedOutput() throws {
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .verify), run: run)
        XCTAssertEqual(cmd.arguments, ["check", "/Volumes/s", "gdrive:BACKUP", "--combined", "-", "--filter", "- /_ARCHIVE/**"])
    }

    func testQuotaBandwidthDryRunAndConfig() throws {
        var dry = run
        dry.dryRun = true
        dry.rcloneConfigPath = "/cfg/rclone.conf"
        let options = TaskOptions(excludes: [], bandwidthLimitKBps: 5000, maxTransferGB: 750)
        let cmd = try RcloneCommandBuilder.command(for: task(options: options), run: dry)
        XCTAssertTrue(cmd.arguments.contains("--dry-run"))
        let bw = try XCTUnwrap(cmd.arguments.firstIndex(of: "--bwlimit"))
        XCTAssertEqual(cmd.arguments[bw + 1], "5000K")
        let mt = try XCTUnwrap(cmd.arguments.firstIndex(of: "--max-transfer"))
        XCTAssertEqual(cmd.arguments[mt + 1], "750G")
        XCTAssertTrue(cmd.arguments.contains("soft"))
        XCTAssertEqual(Array(cmd.arguments.suffix(2)), ["--config", "/cfg/rclone.conf"])
    }

    func testExcludesBecomeFiltersAndSelectionRestrictsToItems() throws {
        let options = TaskOptions(excludes: [".DS_Store"])
        let cmd = try RcloneCommandBuilder.command(for: task(items: ["clip.mov", "Dossier/"], options: options), run: run)
        let filters = cmd.arguments.enumerated().filter { $0.element == "--filter" }.map { cmd.arguments[$0.offset + 1] }
        XCTAssertEqual(filters, ["- .DS_Store", "+ /clip.mov", "+ /clip.mov/**", "+ /Dossier", "+ /Dossier/**", "- **"])
    }

    func testExtraArgumentsAreIncluded() throws {
        let options = TaskOptions(excludes: [], extraArguments: ["--disable", "Copy"])
        let cmd = try RcloneCommandBuilder.command(for: task(options: options), run: run)
        let idx = try XCTUnwrap(cmd.arguments.firstIndex(of: "--disable"))
        XCTAssertEqual(cmd.arguments[idx + 1], "Copy")
    }

    func testSizeCommandIgnoresTheArchiveAndTheUsersExclusions() {
        let options = TaskOptions(excludes: [".DS_Store"])
        let cmd = RcloneCommandBuilder.sizeCommand(for: .cloud(remote: "gdrive", path: "BACKUP"), task: task(options: options), run: run)
        XCTAssertEqual(cmd.arguments, ["size", "--json", "gdrive:BACKUP", "--exclude", "/_ARCHIVE/**", "--exclude", ".DS_Store"])
    }

    func testVerifyHonorsTheSelectionAndTheExclusionsLikeTheCopy() throws {
        let options = TaskOptions(excludes: [".DS_Store"])
        let cmd = try RcloneCommandBuilder.command(for: task(mode: .verify, items: ["keep"], options: options), run: run)
        let filters = cmd.arguments.enumerated().filter { $0.element == "--filter" }.map { cmd.arguments[$0.offset + 1] }
        XCTAssertEqual(filters, ["- /_ARCHIVE/**", "- .DS_Store", "+ /keep", "+ /keep/**", "- **"])
    }

    func testRetentionCleanupOnlyForVersionedMode() throws {
        XCTAssertNil(RcloneCommandBuilder.retentionCleanupCommand(for: task(mode: .mirror), run: run))
        let options = TaskOptions(excludes: [], retentionDays: 30)
        let cmd = try XCTUnwrap(RcloneCommandBuilder.retentionCleanupCommand(for: task(mode: .versioned, options: options), run: run))
        XCTAssertEqual(cmd.arguments, ["delete", "gdrive:BACKUP/_ARCHIVE", "--min-age", "30d", "--rmdirs"])
    }
}
