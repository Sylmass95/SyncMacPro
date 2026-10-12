import XCTest
@testable import SyncKit

final class RsyncCommandBuilderTests: XCTestCase {
    private let run = RunOptions(archiveStamp: "2026-10-12_14-30")

    private func task(
        mode: SyncMode = .copy,
        items: [String] = [],
        options: TaskOptions = TaskOptions(excludes: [])
    ) -> SyncTask {
        SyncTask(
            name: "t",
            source: .local(path: "/src"),
            destination: .network(url: "smb://nas/s", mountPath: "/Volumes/s"),
            sourceItems: items, mode: mode, options: options
        )
    }

    func testCopyArguments() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(), run: run)
        XCTAssertEqual(cmd.engine, .rsync)
        XCTAssertEqual(cmd.arguments, [
            "-rtv", "--inplace", "--partial", "--progress", "--timeout=60", "--out-format=%i|%n",
            "/src/", "/Volumes/s/",
        ])
    }

    func testMirrorArchivesWhatItDeletesOrOverwrites() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .mirror), run: run)
        XCTAssertTrue(cmd.arguments.contains("--delete"))
        XCTAssertTrue(cmd.arguments.contains("--backup"))
        XCTAssertTrue(cmd.arguments.contains("--backup-dir=/Volumes/s/_ARCHIVE/2026-10-12_14-30"))
        XCTAssertTrue(cmd.arguments.contains("--exclude=/_ARCHIVE/"))
    }

    func testMoveRemovesSourceFiles() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .move), run: run)
        XCTAssertTrue(cmd.arguments.contains("--remove-source-files"))
    }

    func testVerifyIsAChecksumDryRun() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .verify), run: run)
        XCTAssertEqual(cmd.arguments, ["-rcn", "--out-format=%i|%n", "/src/", "/Volumes/s/"])
    }

    func testDryRunAddsN() throws {
        var dry = run
        dry.dryRun = true
        let cmd = try RsyncCommandBuilder.command(for: task(mode: .mirror), run: dry)
        XCTAssertTrue(cmd.arguments.contains("-n"))
        XCTAssertFalse(try RsyncCommandBuilder.command(for: task(mode: .mirror), run: run).arguments.contains("-n"))
    }

    func testBandwidthAndExcludes() throws {
        let options = TaskOptions(excludes: [".DS_Store", "*.tmp"], bandwidthLimitKBps: 5000)
        let cmd = try RsyncCommandBuilder.command(for: task(options: options), run: run)
        XCTAssertTrue(cmd.arguments.contains("--bwlimit=5000"))
        XCTAssertTrue(cmd.arguments.contains("--exclude=.DS_Store"))
        XCTAssertTrue(cmd.arguments.contains("--exclude=*.tmp"))
    }

    func testExtraArgumentsAreAppendedBeforeThePaths() throws {
        let options = TaskOptions(excludes: [], extraArguments: ["--checksum"])
        let cmd = try RsyncCommandBuilder.command(for: task(options: options), run: run)
        XCTAssertEqual(Array(cmd.arguments.suffix(3)), ["--checksum", "/src/", "/Volumes/s/"])
    }

    func testSelectedItemsAreCopiedAsFolders() throws {
        let cmd = try RsyncCommandBuilder.command(for: task(items: ["clip.mov", "Dossier/"]), run: run)
        XCTAssertEqual(Array(cmd.arguments.suffix(3)), ["/src/clip.mov", "/src/Dossier", "/Volumes/s/"])
    }

    func testRcloneOnlyModesAreRejected() {
        XCTAssertThrowsError(try RsyncCommandBuilder.command(for: task(mode: .bidirectional), run: run)) {
            XCTAssertEqual($0 as? CommandError, .unsupportedMode(mode: .bidirectional, engine: .rsync))
        }
    }

    func testCloudEndpointIsRejected() {
        let cloud = SyncTask(name: "t", source: .local(path: "/a"), destination: .cloud(remote: "g", path: ""))
        XCTAssertThrowsError(try RsyncCommandBuilder.command(for: cloud, run: run)) {
            XCTAssertEqual($0 as? CommandError, .missingFilesystemPath)
        }
    }

    func testPlanListsDeletionsOnlyForMirror() throws {
        let plan = try RsyncCommandBuilder.planCommand(for: task(mode: .mirror), run: run)
        XCTAssertEqual(Array(plan.arguments.prefix(4)), ["-rtn", "--stats", "--out-format=%l|%n", "--timeout=60"])
        XCTAssertTrue(plan.arguments.contains("--delete"))
        let copyPlan = try RsyncCommandBuilder.planCommand(for: task(), run: run)
        XCTAssertFalse(copyPlan.arguments.contains("--delete"))
    }
}
