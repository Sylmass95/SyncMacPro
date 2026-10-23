import XCTest
@testable import SyncKit

/// 1.7.8 : préparation plus courte. Une copie rsync ne parcourt plus la source que deux fois (calcul préalable, puis
/// copie) au lieu de trois ; rclone liste Drive avec `--fast-list`.
final class Prep178Tests: IntegrationTestCase {
    /// rsync enveloppé : chaque lancement est noté, le premier argument suffit à reconnaître la passe.
    func countingRunner() throws -> (TaskRunner, String) {
        let real = try rsyncPath()
        let calls = sandbox.appendingPathComponent("calls.txt").path
        let wrapper = sandbox.appendingPathComponent("rsync").path
        try "#!/bin/sh\necho \"$*\" >> '\(calls)'\nexec '\(real)' \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let runner = TaskRunner(configuration: RunnerConfiguration(
            rsyncPath: wrapper, workDirectory: sandbox.appendingPathComponent("work"), sampleInterval: 0.05))
        return (runner, calls)
    }

    func testACopyWalksTheSourceTwiceAndStillProtectsNonEmptyFiles() async throws {
        let (runner, calls) = try countingRunner()
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/gros.psb", "")
        try write(destination + "/gros.psb", "contenu précieux")
        try write(source + "/nouveau-vide.txt", "")
        try write(source + "/normal.txt", "x")
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .local(path: destination))
        copy.options.excludes = []
        let result = try await runner.run(copy)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual(read(destination + "/gros.psb"), "contenu précieux")
        XCTAssertTrue(exists(destination + "/nouveau-vide.txt"))
        XCTAssertEqual(read(destination + "/normal.txt"), "x")
        XCTAssertEqual(result.summary.message, EmptySourceGuard.message(count: 1))
        let lines = (read(calls) ?? "").split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "calcul préalable puis copie : \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("--max-size=0") }, "plus de passe séparée pour les fichiers vides")
    }

    func testAMirrorWalksTheSourceTwice() async throws {
        let (runner, calls) = try countingRunner()
        let source = try folder("s"), destination = try folder("d")
        try write(source + "/a.txt", "a")
        try write(destination + "/vieux.txt", "v")
        var mirror = SyncTask(name: "t", source: .local(path: source), destination: .local(path: destination), mode: .mirror)
        mirror.options.excludes = []
        mirror.options.deleteThresholdPercent = 100
        let result = try await runner.run(mirror)
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertEqual((read(calls) ?? "").split(separator: "\n").count, 2)
    }

    func testRcloneListsDriveWithFastList() throws {
        let drive = Endpoint.cloud(remote: "Drive", path: "BACKUP")
        let copy = SyncTask(name: "t", source: .local(path: "/a"), destination: drive)
        XCTAssertTrue(try RcloneCommandBuilder.command(for: copy, run: RunOptions(archiveStamp: "x")).arguments.contains("--fast-list"))
        let fromDrive = SyncTask(name: "t", source: drive, destination: .local(path: "/b"))
        XCTAssertTrue(RcloneCommandBuilder.emptyFilesCommand(for: fromDrive, run: RunOptions(archiveStamp: "x")).arguments.contains("--fast-list"))
        XCTAssertTrue(RcloneCommandBuilder.sizeCommand(for: drive, task: copy, run: RunOptions(archiveStamp: "x")).arguments.contains("--fast-list"))
    }

    func testNoFastListBetweenLocalFoldersNorForBisync() throws {
        let local = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        XCTAssertFalse(try RcloneCommandBuilder.command(for: local, run: RunOptions(archiveStamp: "x")).arguments.contains("--fast-list"))
        let bisync = SyncTask(name: "t", source: .local(path: "/a"), destination: .cloud(remote: "Drive", path: "X"), mode: .bidirectional)
        XCTAssertFalse(try RcloneCommandBuilder.command(for: bisync, run: RunOptions(archiveStamp: "x")).arguments.contains("--fast-list"))
    }
}
