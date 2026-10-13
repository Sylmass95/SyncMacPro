import XCTest
@testable import SyncKit

/// Le vrai rsync derrière l'agent, avec une horloge pilotée : planification, copie, interruption, rattrapage.
final class AgentIntegrationTests: IntegrationTestCase {
    func testScheduledCopyReallyCopiesTheFiles() async throws {
        let configuration = try makeRunner(rsync: true).configuration
        let source = try folder("src"), destination = try folder("dst")
        try write("\(source)/a.txt", "bonjour")
        try write("\(source)/sous/b.txt", "salut")

        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_760_000_000))
        var task = makeTask("réelle", schedule: .everyMinutes(1))
        task.source = .local(path: source)
        task.destination = .local(path: destination)
        try h.save([task])

        let core = h.makeCore(runner: { TaskRunner(configuration: configuration) })
        await core.start()
        await core.tick()
        await core.waitForIdle()

        XCTAssertEqual(try String(contentsOfFile: "\(destination)/a.txt"), "bonjour")
        XCTAssertEqual(try String(contentsOfFile: "\(destination)/sous/b.txt"), "salut")
        let record = try XCTUnwrap(try h.history.list(taskID: task.id).first)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertGreaterThanOrEqual(record.summary?.filesTransferred ?? 0, 2)
    }

    func testCopyInterruptedByAgentShutdownIsCaughtUpAfterRestart() async throws {
        let configuration = try makeRunner(rsync: true).configuration
        let source = try folder("src"), destination = try folder("dst")
        try writeBytes("\(source)/gros.bin", megabytes: 2)

        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_760_000_000))
        var task = makeTask("lente", schedule: .everyMinutes(1))
        task.source = .local(path: source)
        task.destination = .local(path: destination)
        task.options.bandwidthLimitKBps = 400   // ~5 s pour 2 Mo : le temps de l'interrompre
        try h.save([task])

        let first = h.makeCore(runner: { TaskRunner(configuration: configuration) })
        await first.start()
        await first.tick()
        let running = await eventually(timeout: 5) { await first.status().tasks.first?.state == .running }
        XCTAssertTrue(running)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await first.shutdown()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .interrupted)

        // L'agent redémarre quelques secondes plus tard (l'historique trie par heure de début), sans limite de débit :
        // la copie est rattrapée et se termine.
        h.clock.advance(5)
        task.options.bandwidthLimitKBps = nil
        try h.save([task])
        let second = h.makeCore(runner: { TaskRunner(configuration: configuration) })
        await second.start()
        await second.tick()
        await second.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: task.id).first?.status, .succeeded)
        let copied = try FileManager.default.attributesOfItem(atPath: "\(destination)/gros.bin")[.size] as? Int
        XCTAssertEqual(copied, 2 * 1_048_576)
    }
}
