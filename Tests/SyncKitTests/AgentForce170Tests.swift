import XCTest
@testable import SyncKit

/// 1.7.0 : « Forcer » passe outre les limites ; plus de file explicite (anciens messages redirigés) ; copies ponctuelles
/// en haut de la liste.
final class AgentForce170Tests: XCTestCase {
    func task(_ name: String, to destination: Endpoint? = nil) -> SyncTask {
        SyncTask(name: name, source: .local(path: "/Users/moi/\(name)"),
                 destination: destination ?? .local(path: "/Users/moi/copie-\(name)"))
    }

    func harness() throws -> AgentHarness {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        h.conditions.devices.set(["/Volumes/NAS": "nas"])
        return h
    }

    func runner(_ h: AgentHarness, _ name: String) -> FakeRunner? { h.factory.runners.get().first { $0.ranTasks.get().first?.name == name } }

    /// Libère la copie `name` une fois que son exécuteur l'a enregistrée (CI lente).
    func release(_ h: AgentHarness, _ name: String) async {
        _ = await eventually(timeout: 5) { self.runner(h, name) != nil }
        runner(h, name)?.release()
    }

    /// Libère les copies (y compris celles qui partent pendant l'attente) jusqu'au repos de l'agent.
    func finish(_ h: AgentHarness, _ core: AgentCore) async {
        let factory = h.factory
        let releaser = Task {
            while !Task.isCancelled {
                factory.runners.get().forEach { $0.release() }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await core.waitForIdle()
        releaser.cancel()
    }

    func testForceIgnoresTheTwoPlaces() async throws {
        let h = try harness()
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        try await core.force(c.id)
        XCTAssertEqual(h.factory.created, 3)
        await finish(h, core)
    }

    func testForceIgnoresABusyDisk() async throws {
        let h = try harness()
        let a = task("A", to: .local(path: "/Volumes/NAS/a")), b = task("B", to: .local(path: "/Volumes/NAS/b"))
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        XCTAssertEqual(h.factory.created, 1)
        try await core.force(b.id)
        XCTAssertEqual(h.factory.created, 2, "B quitte l'attente et part")
        let queued = await core.status().tasks.filter { $0.state == .queued }
        XCTAssertTrue(queued.isEmpty)
        await finish(h, core)
    }

    func testForceResumesAPausedCopyAtOnce() async throws {
        let h = try harness()
        let a = task("A", to: .local(path: "/Volumes/NAS/a")), b = task("B", to: .local(path: "/Volumes/NAS/b"))
        try h.save([a, b])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.pause(a.id)
        try await core.runNow(b.id)
        try await core.force(a.id)
        XCTAssertEqual(runner(h, "A")?.calls.get().last, "resume")
        let state = await core.status().tasks.first { $0.id == a.id }?.state
        XCTAssertEqual(state, .running)
        await finish(h, core)
    }

    func testForceIsRefusedDuringAGlobalPause() async throws {
        let h = try harness()
        let a = task("A")
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        await core.setGlobalPause(true)
        do { try await core.force(a.id); XCTFail("refus attendu") } catch { XCTAssertEqual(error as? AgentError, .globallyPaused) }
    }

    func testForceIsRefusedWhileARestartIsPending() async throws {
        let h = try harness()
        let identity = Locked<String?>("v1")
        h.configuration.executableIdentity = { identity.get() }
        let a = task("A")
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        identity.set("v2")
        await core.tick()
        do { try await core.force(a.id); XCTFail("refus attendu") } catch { XCTAssertEqual(error as? AgentError, .restartPending) }
    }

    func testForceRefusesADisabledTask() async throws {
        let h = try harness()
        var a = task("A")
        a.isEnabled = false
        try h.save([a])
        let core = h.makeCore()
        await core.start()
        do { try await core.force(a.id); XCTFail("refus attendu") } catch {}
        XCTAssertEqual(h.factory.created, 0)
    }

    func testAOneOffCopyGoesFirstInLine() async throws {
        let h = try harness()
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(a.id)
        try await core.runNow(b.id)
        try await core.runNow(c.id)
        let once = task("Ponctuelle")
        try await core.runOnce(once)
        let first = await core.status().tasks.first
        XCTAssertEqual(first?.isOneOff, true)
        XCTAssertNil(first?.rank)
        await release(h, "A")
        let next = await eventually(timeout: 5) { h.factory.created == 3 && h.factory.runners.get().last?.ranTasks.get().isEmpty == false }
        XCTAssertTrue(next)
        XCTAssertEqual(h.factory.runners.get().last?.ranTasks.get().first?.name, "Ponctuelle", "avant C")
        await finish(h, core)
        let names = await core.status().tasks.map(\.name)
        XCTAssertFalse(names.contains("Ponctuelle"), "disparue une fois finie")
    }

    func testOldQueueRequestsStillWork() async throws {
        let h = try harness()
        let a = task("A"), b = task("B"), c = task("C")
        try h.save([a, b, c])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        XCTAssertEqual(h.factory.created, 1, "« mettre en file » lance")
        try await core.runNow(b.id)
        try await core.runNow(c.id)
        try await core.dequeue(c.id)
        let cState = await core.status().tasks.first { $0.id == c.id }?.state
        XCTAssertEqual(cState, .idle, "« retirer de la file » retire de l'attente")
        await core.setQueueRunning(true)
        XCTAssertEqual(h.factory.created, 2)
        try await core.moveInQueue(c.id, to: 0)
        let order = await core.status().tasks.map(\.name)
        XCTAssertEqual(order.first, "C")
        let status = await core.status()
        XCTAssertNil(status.queue)
        await finish(h, core)
    }
}
