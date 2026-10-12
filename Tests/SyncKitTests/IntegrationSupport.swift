import Foundation
import XCTest
@testable import SyncKit

/// Dossiers temporaires et accès aux vrais binaires pour les tests d'intégration.
class IntegrationTestCase: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("synckit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// rsync 3.x (celui de macOS, openrsync, ne convient pas) : sinon le test est ignoré.
    func rsyncPath() throws -> String {
        guard let path = BinaryLocator.locate(.rsync) else { throw XCTSkip("rsync introuvable (SYNCMACPRO_RSYNC)") }
        let output = try shell(path, ["--version"])
        guard output.contains("version 3.") else {
            throw XCTSkip("rsync 3.x requis (brew install rsync, ou SYNCMACPRO_RSYNC) ; trouvé : \(output.prefix(40))")
        }
        return path
    }

    func rclonePath() throws -> String {
        guard let path = BinaryLocator.locate(.rclone) else { throw XCTSkip("rclone introuvable (SYNCMACPRO_RCLONE)") }
        return path
    }

    func makeRunner(rsync: Bool = false, rclone: Bool = false, sampleInterval: TimeInterval = 0.05) throws -> TaskRunner {
        let config = sandbox.appendingPathComponent("rclone.conf")
        try "".write(to: config, atomically: true, encoding: .utf8)
        return TaskRunner(configuration: RunnerConfiguration(
            rsyncPath: rsync ? try rsyncPath() : nil,
            rclonePath: rclone ? try rclonePath() : nil,
            rcloneConfigPath: config.path,
            workDirectory: sandbox.appendingPathComponent("work"),
            sampleInterval: sampleInterval
        ))
    }

    func folder(_ name: String) throws -> String {
        let url = sandbox.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @discardableResult
    func write(_ path: String, _ content: String) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func writeBytes(_ path: String, megabytes: Int) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let chunk = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        for _ in 0..<megabytes { handle.write(chunk) }
        try handle.close()
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func names(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func shell(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func task(
        _ source: String, _ destination: String, mode: SyncMode = .copy,
        options: TaskOptions = TaskOptions(excludes: []), items: [String] = []
    ) -> SyncTask {
        SyncTask(name: "test", source: .local(path: source), destination: .local(path: destination),
                 sourceItems: items, mode: mode, options: options)
    }

    func waitUntil(timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip("délai dépassé en attendant la condition") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

/// Reçoit les mises à jour d'une exécution, depuis n'importe quel thread.
final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [RunUpdate] = []

    func add(_ update: RunUpdate) { lock.lock(); all.append(update); lock.unlock() }

    var snapshots: [TransferSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return all.compactMap { if case .snapshot(let s) = $0 { return s } else { return nil } }
    }
    var phases: [RunPhase] {
        lock.lock(); defer { lock.unlock() }
        return all.compactMap { if case .phase(let p) = $0 { return p } else { return nil } }
    }
    var latest: TransferSnapshot? { snapshots.last }
}
