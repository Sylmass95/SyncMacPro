import XCTest
@testable import SyncKit

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessOutputLine] = []

    func add(_ line: ProcessOutputLine) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [ProcessOutputLine] { lock.lock(); defer { lock.unlock() }; return storage }
    func texts(_ stream: ProcessOutputLine.Stream) -> [String] { lines.filter { $0.stream == stream }.map(\.text) }
}

final class ProcessRunnerTests: XCTestCase {
    private func run(_ script: String, collector: Collector) throws -> RunningProcess {
        try ProcessRunner.spawn(executable: "/bin/sh", arguments: ["-c", script]) { collector.add($0) }
    }

    func testCapturesBothStreamsAndSplitsOnCarriageReturn() async throws {
        let collector = Collector()
        let process = try run(#"echo out; echo err >&2; printf 'x\ry\n'; printf 'é日本\n'"#, collector: collector)
        let code = await process.waitForExit()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.texts(.stdout), ["out", "x", "y", "é日本"])
        XCTAssertEqual(collector.texts(.stderr), ["err"])
    }

    func testReturnsExitCode() async throws {
        let process = try run("exit 7", collector: Collector())
        let code = await process.waitForExit()
        XCTAssertEqual(code, 7)
    }

    func testWaitingAfterExitStillReturns() async throws {
        let process = try run("exit 3", collector: Collector())
        _ = await process.waitForExit()
        let again = await process.waitForExit()
        XCTAssertEqual(again, 3)
    }

    func testLargeOutputIsNotLost() async throws {
        let collector = Collector()
        let process = try run("i=0; while [ $i -lt 5000 ]; do echo line$i; i=$((i+1)); done", collector: collector)
        _ = await process.waitForExit()
        XCTAssertEqual(collector.texts(.stdout).count, 5000)
        XCTAssertEqual(collector.texts(.stdout).last, "line4999")
    }

    func testPauseFreezesOutputAndResumeContinues() async throws {
        let collector = Collector()
        let process = try run("i=0; while [ $i -lt 10 ]; do echo $i; i=$((i+1)); sleep 0.2; done", collector: collector)
        try await waitUntil { collector.lines.count >= 2 }

        process.pause()
        try await Task.sleep(nanoseconds: 400_000_000)      // laisse arriver ce qui était déjà en route
        let frozenAt = collector.lines.count
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(collector.lines.count, frozenAt, "aucune sortie pendant la pause")

        process.resume()
        let code = await process.waitForExit()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.texts(.stdout), (0..<10).map(String.init))
    }

    func testTerminateKillsTheWholeGroupEvenWhenPaused() async throws {
        let process = try run("sleep 30 & wait", collector: Collector())
        try await Task.sleep(nanoseconds: 300_000_000)
        process.pause()
        process.terminate()

        let code = await withTimeout(seconds: 5) { await process.waitForExit() }
        XCTAssertEqual(code, 128 + SIGTERM)
        XCTAssertEqual(killpg(process.pid, 0), -1)          // plus aucun processus dans le groupe
        XCTAssertEqual(errno, ESRCH)
    }

    /// I5 : un enfant ne doit pas hériter des descripteurs ouverts par l'appelant (sinon le lecteur d'un autre
    /// lancement ne voit jamais la fin de son flux tant que cet enfant vit).
    func testChildrenDoNotInheritTheCallersOtherDescriptors() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let process = try run("sleep 3", collector: Collector())
        close(fds[1])                       // la seule extrémité d'écriture restante serait celle héritée par l'enfant
        var watched = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
        let ready = poll(&watched, 1, 1_500)
        close(fds[0])
        process.terminate()
        _ = await process.waitForExit()
        XCTAssertEqual(ready, 1, "fin de flux attendue immédiatement : l'enfant ne doit détenir aucun descripteur de l'appelant")
    }

    /// I6 : un moteur qui ignore SIGTERM (montage bloqué, nettoyage trop long) ne doit pas geler l'exécution.
    func testTerminateEscalatesToKillWhenTheProgramIgnoresSigterm() async throws {
        let process = try run(#"trap '' TERM; while true; do sleep 1; done"#, collector: Collector())
        try await Task.sleep(nanoseconds: 300_000_000)
        // filet de sécurité du test seul : sans l'escalade, il tuerait le processus après 6 s (et le test échoue sur la durée)
        let pid = process.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { killpg(pid, SIGKILL) }

        let started = Date()
        process.terminate(killAfter: 0.5)
        let code = await process.waitForExit()

        XCTAssertEqual(code, 128 + SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "l'escalade doit tuer le processus peu après le délai de grâce")
    }

    func testSpawnFailureIsReported() {
        XCTAssertThrowsError(try ProcessRunner.spawn(executable: "/nonexistent/program", arguments: []) { _ in }) {
            guard case ProcessError.spawnFailed = $0 else { return XCTFail("mauvaise erreur : \($0)") }
        }
    }

    func testDecodeStatus() {
        XCTAssertEqual(ProcessRunner.decode(7 << 8), 7)
        XCTAssertEqual(ProcessRunner.decode(SIGKILL), 128 + SIGKILL)
    }

    // MARK: aides

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("délai dépassé") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

final class BinaryLocatorTests: XCTestCase {
    func testEnvironmentOverrideWins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rsync3 = try fakeRsync(in: dir, name: "mon-rsync", version: "rsync  version 3.4.1  protocol version 32")
        let path = BinaryLocator.locate(.rsync, environment: ["SYNCMACPRO_RSYNC": rsync3], searchDirectories: [])
        XCTAssertEqual(path, rsync3)
    }

    /// L'outil rsync de macOS est openrsync : ses sorties et ses options diffèrent (simulation fausse, miroir en échec).
    func testOpenrsyncIsSkippedForTheNextCandidate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let openrsync = try fakeRsync(in: dir.appendingPathComponent("a"), name: "rsync", version: "openrsync: protocol version 29")
        let rsync3 = try fakeRsync(in: dir.appendingPathComponent("b"), name: "rsync", version: "rsync  version 3.4.1  protocol version 32")
        XCTAssertEqual(BinaryLocator.locate(.rsync, environment: ["SYNCMACPRO_RSYNC": openrsync], searchDirectories: []), nil)
        XCTAssertEqual(
            BinaryLocator.locate(.rsync, environment: [:], searchDirectories: [dir.appendingPathComponent("a").path, dir.appendingPathComponent("b").path]),
            rsync3
        )
    }

    func testMissingRsyncIsExplainedInFrench() {
        let message = RunnerError.binaryMissing(.rsync).errorDescription ?? ""
        XCTAssertTrue(message.contains("rsync 3"), message)
        XCTAssertTrue(message.contains("brew install rsync"), message)
        XCTAssertTrue((RunnerError.binaryMissing(.rclone).errorDescription ?? "").contains("rclone"))
    }

    func fakeRsync(in dir: URL, name: String, version: String) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho '\(version)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testBundleDirectoryIsUsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("rclone")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertEqual(BinaryLocator.locate(.rclone, environment: [:], bundleDirectory: dir.path), fake.path)
    }

    func testMissingBinaryReturnsNil() {
        let path = BinaryLocator.locate(
            .rclone, environment: ["SYNCMACPRO_RCLONE": "/nope"], bundleDirectory: "/nope", searchDirectories: []
        )
        XCTAssertNil(path)
    }
}
