import XCTest
@testable import SyncKit

final class DirectoryProgressTests: IntegrationTestCase {
    func testADirectoryIsDoneWhenAllItsFilesAreCopied() {
        var progress = RcloneDirectoryProgress(directoriesOfPendingFiles: ["a": 2, "a/b": 1, "": 1])
        XCTAssertEqual(progress.total, 3)
        progress.fileCopied("a/x.txt")
        XCTAssertEqual(progress.done, 0)
        progress.fileCopied("a/y.txt")
        XCTAssertEqual(progress.done, 1)
        progress.fileCopied("a/b/z.txt")
        progress.fileCopied("racine.txt")
        XCTAssertEqual(progress.done, 3)
        progress.fileCopied("a/b/z.txt")
        XCTAssertEqual(progress.done, 3)
    }

    func testCopiedLinesAreParsed() {
        let line = #"{"level":"info","msg":"Copied (new)","object":"a/b/z.txt","objectType":"*local.Object"}"#
        XCTAssertEqual(RcloneOutputParser.parse(line: line), .copied(name: "a/b/z.txt"))
        let replaced = #"{"level":"info","msg":"Copied (replaced existing)","object":"x.txt"}"#
        XCTAssertEqual(RcloneOutputParser.parse(line: replaced), .copied(name: "x.txt"))
    }

    func testPendingFilesAreCountedPerDirectoryFromADryRun() {
        var dirs: [String: Int] = [:]
        RcloneDirectoryProgress.notePending(#"{"level":"notice","msg":"Skipped copy as --dry-run is set (size 12)","object":"a/b/z.txt"}"#, into: &dirs)
        RcloneDirectoryProgress.notePending(#"{"level":"notice","msg":"Skipped copy as --dry-run is set (size 1)","object":"top.txt"}"#, into: &dirs)
        RcloneDirectoryProgress.notePending(#"{"level":"notice","msg":"Skipped delete as --dry-run is set","object":"old.txt"}"#, into: &dirs)
        XCTAssertEqual(dirs, ["a/b": 1, "": 1])
    }

    // Copie rclone réelle : dossiers suivis, bilan avec dossiers et vitesse moyenne.
    func testRcloneRunReportsDirectoriesAndAverageSpeed() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s"), destination = try folder("d")
        for dir in ["a", "a/b", "c"] { for index in 0..<3 { try write(source + "/\(dir)/f\(index).txt", "x") } }
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":local", path: destination))
        copy.options.excludes = []
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(result.snapshot.totalDirs, 3)
        XCTAssertEqual(result.snapshot.dirsDone, 3)
        XCTAssertEqual(result.summary.directories, 3)
        XCTAssertNotNil(result.summary.averageSpeed)
    }

    // rsync aussi : dossiers et vitesse moyenne dans le bilan.
    func testRsyncSummaryHasDirectories() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        for dir in ["a", "b"] { try write(source + "/\(dir)/f.txt", "x") }
        var mirror = task(source, destination, mode: .mirror)
        mirror.options.excludes = []
        let result = try await runner.run(mirror)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertNotNil(result.summary.directories)
    }
}
