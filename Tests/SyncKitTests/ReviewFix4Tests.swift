import XCTest
@testable import SyncKit

/// Corrections issues de la relecture finale de la branche 4 (agent).
final class ReviewFix4AgentTests: XCTestCase {
    // I1 : l'arrêt de l'agent attend la fin de rclone puis supprime les connexions à moitié créées.
    func testShutdownRemovesHalfMadeRemotes() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_driveid")))])
        let core = h.makeCore(remotes: remotes)
        await core.start()
        _ = try await core.configureRemote(.start(name: "OneDrive", type: "onedrive", parameters: [:]))
        await core.shutdown()
        XCTAssertEqual(remotes.idleWaits.get(), 1, "rclone doit avoir fini avant le nettoyage")
        XCTAssertEqual(remotes.deleted.get(), ["OneDrive"])
    }

    // I3 : deux créations du même nom à la fois : la seconde est refusée, même pendant la lecture de la liste.
    func testConcurrentStartsAreRefused() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let gate = TestGate()
        remotes.listGate.set(gate)
        let core = h.makeCore(remotes: remotes)
        let first = Task { try await core.configureRemote(.start(name: "Drive", type: "drive", parameters: [:])) }
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await core.configureRemote(.start(name: "Drive", type: "drive", parameters: [:]))
            XCTFail("la seconde création doit être refusée")
        } catch {
            XCTAssertEqual(error as? AgentError, .remoteBusy)
        }
        gate.release()
        _ = try await first.value
        XCTAssertEqual(remotes.steps.get().count, 1)
    }

    // Une reconnexion ne supprime jamais, même si une création de ce nom était restée inachevée.
    func testReconnectNeverDeletes() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_driveid"))), .failure(.rclone("refus"))])
        let core = h.makeCore(remotes: remotes)
        _ = try await core.configureRemote(.start(name: "OneDrive", type: "onedrive", parameters: [:]))
        do { _ = try await core.configureRemote(.reconnect(name: "OneDrive")); XCTFail() } catch {}
        await core.cancelRemoteConfiguration("OneDrive")
        XCTAssertTrue(remotes.deleted.get().isEmpty)
    }
}
