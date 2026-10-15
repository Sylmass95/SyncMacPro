import XCTest
@testable import SyncKit

final class RsyncBandwidthTests: IntegrationTestCase {
    func testRsyncUsesTheLowerSideInKiB() {
        XCTAssertEqual(RsyncCommandBuilder.bwlimitKBps(BandwidthRate(upBytesPerSecond: 2_048_000, downBytesPerSecond: 1_024_000)), 1000)
        XCTAssertNil(RsyncCommandBuilder.bwlimitKBps(.unlimited))
    }

    // Copie lente (1 Mo/s), plafond relevé en route : rsync est relancé, reprend et finit vite, fichier complet.
    func testRaisingTheCapRestartsRsyncAndFinishes() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try writeBytes(source + "/gros.bin", megabytes: 30)
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let started = Date()
        let finished = Locked(false)
        let lines = Locked<[String]>([])
        let running = Task { () -> RunResult in
            let result = try await runner.run(task(source, destination)) { update in
                if case .line(let text) = update { lines.update { $0.append(text) } }
            }
            finished.set(true)
            return result
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(finished.get(), "la limite de départ s'applique")
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 200_000_000, downBytesPerSecond: 200_000_000))
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        let copied = try FileManager.default.attributesOfItem(atPath: destination + "/gros.bin")[.size] as? Int
        XCTAssertEqual(copied, 30 * 1_048_576)
        XCTAssertTrue(lines.get().contains { $0.contains("rsync est relancé") })
        XCTAssertEqual(result.summary.errors, 0, "l'arrêt pour relance n'est pas une erreur")
    }

    // Un miroir relancé ne refait pas son garde-fou et ne supprime rien de plus.
    func testMirrorRestartKeepsItsPlan() async throws {
        let runner = try makeRunner(rsync: true)
        let source = try folder("s"), destination = try folder("d")
        try writeBytes(source + "/gros.bin", megabytes: 20)
        try write(destination + "/en-trop.txt", "x")
        for index in 0..<10 { try write(destination + "/garde\(index).txt", "x"); try write(source + "/garde\(index).txt", "x") }
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let running = Task { try await runner.run(task(source, destination, mode: .mirror)) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        runner.setBandwidth(.unlimited)
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertFalse(exists(destination + "/en-trop.txt"))
        XCTAssertEqual(names(in: destination).filter { $0.hasPrefix("garde") }.count, 10)
        let copied = try FileManager.default.attributesOfItem(atPath: destination + "/gros.bin")[.size] as? Int
        XCTAssertEqual(copied, 20 * 1_048_576)
    }
}
