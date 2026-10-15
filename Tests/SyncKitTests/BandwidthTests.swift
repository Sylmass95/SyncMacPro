import XCTest
@testable import SyncKit

final class BandwidthTests: XCTestCase {
    let types = ["Google Drive": "drive", "nas": "smb", "S3": "s3"]

    func task(_ source: Endpoint, _ destination: Endpoint, limitKBps: Int? = nil) -> SyncTask {
        var t = SyncTask(name: "t", source: source, destination: destination)
        t.options.bandwidthLimitKBps = limitKBps
        return t
    }

    func testDirectionFollowsWhereInternetIs() {
        let drive = Endpoint.cloud(remote: "Google Drive", path: "a"), nas = Endpoint.cloud(remote: "nas", path: "b")
        XCTAssertEqual(BandwidthPlanner.direction(of: task(drive, nas), remoteTypes: types), .download)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(nas, drive), remoteTypes: types), .upload)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.local(path: "/a"), nas), remoteTypes: types), .local)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.local(path: "/a"), .local(path: "/b")), remoteTypes: types), .local)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.cloud(remote: "S3", path: "a"), drive), remoteTypes: types), .both)
        XCTAssertEqual(BandwidthPlanner.direction(of: task(.cloud(remote: "inconnue", path: "a"), .local(path: "/b")), remoteTypes: types), .download,
                       "type inconnu : on suppose internet (le plafond protège la connexion)")
    }

    func testSameDirectionSharesTheCapAndTaskLimitWinsWhenLower() {
        let limits = BandwidthLimits(downloadMbps: 100, uploadMbps: 40, localMbps: nil)
        let a = UUID(), b = UUID(), c = UUID()
        let drive = Endpoint.cloud(remote: "Google Drive", path: "x"), nas = Endpoint.cloud(remote: "nas", path: "y")
        let rates = BandwidthPlanner.rates(for: [
            (a, task(drive, nas)), (b, task(drive, nas, limitKBps: 1000)), (c, task(.local(path: "/a"), .local(path: "/b"))),
        ], limits: limits, remoteTypes: types)
        XCTAssertEqual(rates[a]?.downBytesPerSecond, 6_250_000, "100 Mbit/s partagés par deux")
        XCTAssertEqual(rates[b]?.downBytesPerSecond, 1_024_000, "la limite de la tâche (1000 Ko/s) est plus basse")
        XCTAssertEqual(rates[a]?.upBytesPerSecond, 6_250_000, "le plafond du sens de la tâche vaut pour les deux côtés")
        XCTAssertEqual(rates[c], .unlimited, "pas de plafond local")
    }

    func testLocalCapAppliesToBothSides() {
        let id = UUID()
        let rates = BandwidthPlanner.rates(for: [(id, task(.local(path: "/a"), .cloud(remote: "nas", path: "b")))],
                                           limits: BandwidthLimits(localMbps: 800), remoteTypes: types)
        XCTAssertEqual(rates[id], BandwidthRate(upBytesPerSecond: 100_000_000, downBytesPerSecond: 100_000_000))
    }

    func testAgentAppliesRatesAtStartAndWhenSettingsChange() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let copy = SyncTask(name: "Drive → NAS", source: .cloud(remote: "Google Drive", path: "a"),
                            destination: .cloud(remote: "nas", path: "b"), schedule: .manual)
        try h.save([copy])
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Google Drive", type: "drive"), RemoteInfo(name: "nas", type: "smb")])
        let settings = AgentSettingsStore(url: h.directory.appendingPathComponent("settings.json"))
        let core = h.makeCore(remotes: remotes, settings: settings)
        await core.start()
        await core.refreshRemoteTypes()
        await core.setBandwidth(BandwidthLimits(downloadMbps: 80))
        try await core.runNow(copy.id)
        let runner = h.factory.runners.get()[0]
        XCTAssertEqual(runner.rates.get().last?.downBytesPerSecond, 10_000_000)
        await core.setBandwidth(BandwidthLimits(downloadMbps: 160))
        XCTAssertEqual(runner.rates.get().last?.downBytesPerSecond, 20_000_000, "changement appliqué à chaud")
        XCTAssertEqual(settings.load().downloadMbps, 160, "enregistré")
        let shown = await core.status().bandwidth
        XCTAssertEqual(shown, BandwidthLimits(downloadMbps: 160))
        runner.release()
        await core.waitForIdle()
        let again = h.makeCore(remotes: remotes, settings: settings)
        await again.start()
        let reloaded = await again.status().bandwidth
        XCTAssertEqual(reloaded?.downloadMbps, 160, "relu au démarrage")
    }
}
