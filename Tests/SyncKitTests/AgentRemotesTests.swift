import XCTest
@testable import SyncKit

final class AgentRemotesTests: XCTestCase {
    func testCreateValidatesTheNameFirst() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Drive", type: "drive")])
        let core = h.makeCore(remotes: remotes)
        do {
            _ = try await core.configureRemote(.start(name: "drive", type: "drive", parameters: [:]))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidRemote("Ce nom est déjà utilisé par une autre connexion."))
        }
        do {
            _ = try await core.configureRemote(.start(name: "a:b", type: "s3", parameters: [:]))
            XCTFail()
        } catch {
            guard case .invalidRemote = error as? AgentError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(remotes.steps.get().isEmpty, "rien n'est demandé à rclone")
    }

    func testFailedCreationIsRolledBack() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_is_local"))), .failure(.rclone("refus"))])
        let core = h.makeCore(remotes: remotes)
        let first = try await core.configureRemote(.start(name: "Dropbox", type: "dropbox", parameters: [:]))
        guard case .question = first else { return XCTFail() }
        do {
            _ = try await core.configureRemote(.answer(name: "Dropbox", state: "s", result: "true"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidRemote("refus"))
        }
        XCTAssertEqual(remotes.deleted.get(), ["Dropbox"], "une création ratée ne laisse rien")
    }

    func testCancelDeletesAHalfMadeRemote() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_is_local")))])
        let core = h.makeCore(remotes: remotes)
        _ = try await core.configureRemote(.start(name: "Dropbox", type: "dropbox", parameters: [:]))
        await core.cancelRemoteConfiguration("Dropbox")
        XCTAssertEqual(remotes.cancelled.get(), ["Dropbox"])
        XCTAssertEqual(remotes.deleted.get(), ["Dropbox"])
        // Une reconnexion annulée ne supprime pas la connexion existante.
        remotes.outcomes.set([.success(.question(RemoteQuestion(state: "s", option: "config_is_local")))])
        _ = try await core.configureRemote(.reconnect(name: "Existante"))
        await core.cancelRemoteConfiguration("Existante")
        XCTAssertEqual(remotes.deleted.get(), ["Dropbox"])
    }

    func testOneConfigurationAtATimePerName() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let gate = TestGate()
        remotes.gate.set(gate)
        let core = h.makeCore(remotes: remotes)
        let pending = Task { try await core.configureRemote(.start(name: "S3", type: "s3", parameters: [:])) }
        _ = await eventually { remotes.steps.get().count == 1 }
        do {
            _ = try await core.configureRemote(.answer(name: "S3", state: "x", result: "y"))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .remoteBusy)
        }
        gate.release()
        _ = try await pending.value
    }

    func testDeleteIsRefusedWhileATaskUsesTheRemote() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Drive", type: "drive")])
        try h.save([SyncTask(name: "Photos vers Drive", source: .local(path: "/a"), destination: .cloud(remote: "Drive", path: "x"))])
        let core = h.makeCore(remotes: remotes)
        await core.start()
        do {
            try await core.deleteRemote("Drive")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentError, .remoteInUse(["Photos vers Drive"]))
        }
        XCTAssertTrue(remotes.deleted.get().isEmpty)
    }

    func testShutdownStopsConfigurations() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let core = h.makeCore(remotes: remotes)
        await core.start()
        await core.shutdown()
        XCTAssertEqual(remotes.cancelled.get(), ["*"])
    }

    func testWithoutRclone() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        do { _ = try await core.listRemotes(); XCTFail() } catch { XCTAssertEqual(error as? AgentError, .rcloneMissing) }
    }

    func testRouterSpeaksVersion4() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        remotes.remotes.set([RemoteInfo(name: "Drive", type: "drive")])
        let core = h.makeCore(remotes: remotes)
        let request = try JSONEncoder().encode(AgentRequestEnvelope(request: .listRemotes))
        let data = await AgentRouter.handle(request, core: core)
        let reply = try JSONDecoder().decode(AgentResponseEnvelope.self, from: data)
        XCTAssertEqual(reply.version, 4)
        XCTAssertEqual(reply.response, .remotes([RemoteInfo(name: "Drive", type: "drive")]))
    }

    func testRealRcloneThroughTheAgent() async throws {
        guard let rclone = BinaryLocator.locate(.rclone) else { throw XCTSkip("rclone introuvable") }
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let config = h.directory.appendingPathComponent("rclone.conf").path
        let core = h.makeCore(remotes: RcloneConfigurator(rclonePath: rclone, configPath: config))
        let outcome = try await core.configureRemote(.start(name: "Local", type: "alias", parameters: ["remote": h.directory.path]))
        XCTAssertEqual(outcome, .done)
        let listed = try await core.listRemotes()
        XCTAssertEqual(listed.map(\.name), ["Local"])
        let test = try await core.testRemote("Local")
        XCTAssertTrue(test.ok)
        try await core.deleteRemote("Local")
        let after = try await core.listRemotes()
        XCTAssertTrue(after.isEmpty)
    }
}
