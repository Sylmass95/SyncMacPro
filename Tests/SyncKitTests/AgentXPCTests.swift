import XCTest
@testable import SyncKit

final class AgentXPCTests: XCTestCase {
    struct Server {
        let client: AgentClient
        let core: AgentCore
        let listener: NSXPCListener
        let delegate: AgentListenerDelegate
    }

    func makeServer(_ h: AgentHarness, timeout: TimeInterval = 5) async -> Server {
        let core = h.makeCore()
        await core.start()
        let delegate = AgentListenerDelegate(core: core)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = AgentClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
        return Server(client: client, core: core, listener: listener, delegate: delegate)
    }

    func testStatusAndTaskListGoThroughXPC() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        try h.save([makeTask("alpha", schedule: .manual)])
        let server = await makeServer(h)
        let status = try await server.client.status()
        XCTAssertEqual(status.tasks.map(\.name), ["alpha"])
        let tasks = try await server.client.listTasks()
        XCTAssertEqual(tasks.map(\.name), ["alpha"])
        withExtendedLifetime(server) {}
    }

    func testCommandsAndHistoryGoThroughXPC() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let server = await makeServer(h)
        try await server.client.perform(.runNow(task.id))
        await server.core.waitForIdle()
        let records = try await server.client.history(taskID: task.id, limit: 5)
        XCTAssertEqual(records.map(\.status), [.succeeded])
        withExtendedLifetime(server) {}
    }

    func testAgentErrorsComeBackAsClientErrors() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let server = await makeServer(h)
        do {
            try await server.client.perform(.pause(UUID()))
            XCTFail("une erreur était attendue")
        } catch {
            XCTAssertEqual(error as? AgentClientError, .agent(.notRunning))
        }
        withExtendedLifetime(server) {}
    }

    func testWatcherReceivesEvents() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let server = await makeServer(h)
        let events = Locked<[AgentEvent]>([])
        let watch = try await server.client.watch { events.set(events.get() + [$0]) }
        try await server.client.perform(.runNow(task.id))
        let done = await eventually {
            events.get().contains { if case .taskFinished(task.id, .succeeded, _) = $0 { return true } else { return false } }
        }
        XCTAssertTrue(done)
        XCTAssertTrue(events.get().contains(.taskStarted(task.id)))
        watch.cancel()
        withExtendedLifetime(server) {}
    }

    func testIncompatibleVersionIsReportedClearly() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let server = await makeServer(h)
        let raw = Data(#"{"version":99,"request":"status"}"#.utf8)
        let reply = try await server.client.sendRaw(raw)
        let envelope = try JSONDecoder().decode(AgentResponseEnvelope.self, from: reply)
        XCTAssertEqual(envelope.response, .error(.versionMismatch(agent: agentProtocolVersion, client: 99)))
        withExtendedLifetime(server) {}
    }

    func testAbsentAgentIsReportedAsUnreachable() async {
        let client = AgentClient(timeout: 2) { NSXPCConnection(machServiceName: "com.sylvain.syncmacpro.tests.absent") }
        do {
            _ = try await client.status()
            XCTFail("une erreur était attendue")
        } catch {
            XCTAssertEqual(error as? AgentClientError, .unreachable)
        }
    }

    func testWatcherIsToldWhenTheAgentConnectionEnds() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let delegate = AgentListenerDelegate(core: core)
        let serverConnections = Locked<[NSXPCConnection]>([])
        delegate.onNewConnection = { serverConnections.set(serverConnections.get() + [$0]) }
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = AgentClient(timeout: 5) { NSXPCConnection(listenerEndpoint: endpoint) }

        let ended = Locked(false)
        let watch = try await client.watch({ _ in }, onEnd: { ended.set(true) })
        // L'agent « meurt » : sa connexion est coupée côté serveur.
        serverConnections.get().forEach { $0.invalidate() }
        let told = await eventually { ended.get() }
        XCTAssertTrue(told, "le client doit savoir que l'agent a disparu")
        withExtendedLifetime((watch, listener, delegate)) {}
    }

    func testCancellingAWatchDoesNotReportAnEnd() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let server = await makeServer(h)
        let ended = Locked(false)
        let watch = try await server.client.watch({ _ in }, onEnd: { ended.set(true) })
        watch.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(ended.get(), "annuler soi-même n'est pas une fin de connexion")
        withExtendedLifetime(server) {}
    }

    func testObserverRegisteredAfterTearDownIsRemoved() async throws {
        final class StubObserver: NSObject, AgentObserverXPC { func event(_ data: Data) {} }
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let handler = AgentConnectionHandler(core: core)
        handler.tearDown()   // le client s'est déconnecté avant que l'abonnement n'arrive
        let replied = Locked(false)
        handler.subscribe(StubObserver()) { replied.set(true) }
        let done = await eventually { replied.get() }
        XCTAssertTrue(done)
        let count = await core.observerCount
        XCTAssertEqual(count, 0, "un observateur orphelin ne doit pas rester enregistré")
    }
}
