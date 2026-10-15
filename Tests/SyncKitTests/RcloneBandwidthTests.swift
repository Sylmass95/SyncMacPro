import XCTest
@testable import SyncKit

final class RcloneBandwidthTests: IntegrationTestCase {
    func testBwlimitValueIsUploadColonDownloadInKiB() {
        XCTAssertEqual(RcloneCommandBuilder.bwlimitValue(BandwidthRate(upBytesPerSecond: 1_024_000, downBytesPerSecond: nil)), "1000K:off")
        XCTAssertEqual(RcloneCommandBuilder.bwlimitValue(BandwidthRate(upBytesPerSecond: nil, downBytesPerSecond: 2_048)), "off:2K")
        XCTAssertNil(RcloneCommandBuilder.bwlimitValue(.unlimited))
    }

    func testSocketPathFitsTheUnixLimit() {
        XCTAssertLessThan(RcloneRemoteControl.socketPath().utf8.count, 104)
    }

    func testCommandCarriesTheLimitAndTheControlSocket() throws {
        let task = SyncTask(name: "t", source: .cloud(remote: "Drive", path: "a"), destination: .local(path: "/b"))
        var run = RunOptions(archiveStamp: "s")
        run.bandwidth = BandwidthRate(upBytesPerSecond: nil, downBytesPerSecond: 1_024_000)
        run.rcSocketPath = "/tmp/x.sock"
        let args = try RcloneCommandBuilder.command(for: task, run: run).arguments
        XCTAssertTrue(args.joined(separator: " ").contains("--bwlimit off:1000K"))
        XCTAssertTrue(args.joined(separator: " ").contains("--rc --rc-addr unix:///tmp/x.sock --rc-no-auth"))
    }

    // Copie réelle vers la mémoire : lente au départ (1 Mo/s), accélérée à chaud (100 Mo/s), elle finit vite.
    func testRateChangesWhileCopying() async throws {
        let runner = try makeRunner(rclone: true)
        let source = try folder("s")
        try writeBytes(source + "/gros.bin", megabytes: 40)
        var copy = SyncTask(name: "t", source: .local(path: source), destination: .cloud(remote: ":memory", path: "b"))
        copy.options.excludes = []
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 1_000_000, downBytesPerSecond: 1_000_000))
        let started = Date()
        let finished = Locked(false)
        let frozen = copy   // Swift 5.10 : pas de `var` capturée dans une closure concurrente
        let running = Task { () -> RunResult in
            let result = try await runner.run(frozen)
            finished.set(true)
            return result
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(finished.get(), "à 1 Mo/s, 40 Mo ne sont pas copiés en 3 s : la limite de départ s'applique")
        runner.setBandwidth(BandwidthRate(upBytesPerSecond: 100_000_000, downBytesPerSecond: 100_000_000))
        let result = try await running.value
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "à 1 Mo/s il faudrait 40 s")
    }
}
