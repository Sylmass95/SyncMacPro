import XCTest
@testable import SyncKit

/// Faux montage : le « volume » d'un partage est un dossier du bac à sable, créé au montage.
final class FakeShares: ShareMounting, @unchecked Sendable {
    let base: String
    let mounted = Locked<Set<String>>([])
    let mountCalls = Locked<[String]>([])
    /// Erreur rendue par `mount` ; `nil` : le montage réussit.
    let mountError = Locked<String?>(nil)

    init(base: String) { self.base = base }

    func root(of mountPath: String) -> String? {
        guard mountPath.hasPrefix(base + "/") else { return nil }
        let name = mountPath.dropFirst(base.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return name.isEmpty ? nil : base + "/" + name
    }

    func isMounted(_ root: String) -> Bool { mounted.get().contains(root) }

    func mount(_ url: String, timeout: TimeInterval) async -> String? {
        mountCalls.update { $0.append(url) }
        if let error = mountError.get() { return error }
        let name = String(url.split(separator: "/").last ?? "")
        let root = base + "/" + name
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        mounted.update { $0.insert(root) }
        return nil
    }
}

/// 1.6.5 : partages réseau. Un partage non monté est monté avant la copie ; un NAS injoignable fait attendre la tâche
/// (nouvel essai toutes les quelques minutes) au lieu d'un échec, et le message ne parle plus d'autorisation de macOS.
final class NetworkShareRunnerTests: IntegrationTestCase {
    func runner(_ shares: FakeShares, probe: @escaping @Sendable (String) -> (String, [String]) = RunnerConfiguration.defaultAccessProbe,
                timeout: TimeInterval = 15) throws -> TaskRunner {
        var configuration = RunnerConfiguration(rsyncPath: try rsyncPath(), workDirectory: sandbox.appendingPathComponent("w"))
        configuration.shares = shares
        configuration.accessProbe = probe
        configuration.accessProbeTimeout = timeout
        return TaskRunner(configuration: configuration)
    }

    func toShare(_ source: String, _ shares: FakeShares) -> SyncTask {
        SyncTask(name: "test", source: .local(path: source),
                 destination: .network(url: "smb://moi@nas/NAS", mountPath: shares.base + "/NAS/Sauvegarde"))
    }

    func testAnUnmountedShareIsMountedBeforeTheCopy() async throws {
        let source = try folder("Bureau")
        try Data("x".utf8).write(to: URL(fileURLWithPath: source).appendingPathComponent("a.txt"))
        let shares = FakeShares(base: try folder("Volumes"))
        let result = try await runner(shares).run(toShare(source, shares))
        XCTAssertEqual(shares.mountCalls.get(), ["smb://moi@nas/NAS"])
        XCTAssertEqual(result.status, .succeeded, result.summary.message ?? "")
        XCTAssertNil(result.shareUnavailable)
        XCTAssertTrue(exists(shares.base + "/NAS/Sauvegarde/a.txt"))
    }

    func testAMountedShareIsNotMountedAgain() async throws {
        let source = try folder("Bureau")
        let shares = FakeShares(base: try folder("Volumes"))
        _ = await shares.mount("smb://moi@nas/NAS", timeout: 1)
        shares.mountCalls.set([])
        _ = try await runner(shares).run(toShare(source, shares))
        XCTAssertEqual(shares.mountCalls.get(), [])
    }

    func testAShareThatCannotBeMountedIsUnavailable() async throws {
        let source = try folder("Bureau")
        let shares = FakeShares(base: try folder("Volumes"))
        shares.mountError.set("hôte injoignable")
        let result = try await runner(shares).run(toShare(source, shares))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.retryable)
        XCTAssertEqual(result.shareUnavailable, "NAS")
        let message = try XCTUnwrap(result.summary.message)
        XCTAssertTrue(message.contains("« NAS »"), message)
        XCTAssertTrue(message.contains("hôte injoignable"), message)
    }

    func testAMountedShareThatDoesNotAnswerIsUnavailableNotOnlyAPermissionQuestion() async throws {
        let source = try folder("Bureau")
        let shares = FakeShares(base: try folder("Volumes"))
        _ = await shares.mount("smb://moi@nas/NAS", timeout: 1)
        let started = Date()
        let result = try await runner(shares, probe: { path in
            path.hasPrefix(shares.base) ? ("/bin/sleep", ["30"]) : ("/bin/ls", ["-f", path])
        }, timeout: 0.5).run(toShare(source, shares))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.shareUnavailable, "NAS")
        let message = try XCTUnwrap(result.summary.message)
        XCTAssertTrue(message.contains("ne répond pas"), message)
        XCTAssertTrue(message.contains("NAS éteint"), message)
    }

    func testTheShareRootIsTheVolumeUnderVolumes() {
        XCTAssertEqual(NetworkShare.volumesRoot(of: "/Volumes/Documents/PERSO-FILES"), "/Volumes/Documents")
        XCTAssertEqual(NetworkShare.volumesRoot(of: "/Volumes/03_ARCHIVES_GLOBALES"), "/Volumes/03_ARCHIVES_GLOBALES")
        XCTAssertEqual(NetworkShare.volumesRoot(of: "/Volumes/03_ARCHIVES_GLOBALES/"), "/Volumes/03_ARCHIVES_GLOBALES")
        XCTAssertNil(NetworkShare.volumesRoot(of: "/Users/moi/NAS"))
        XCTAssertNil(NetworkShare.volumesRoot(of: "/Volumes/"))
    }

    /// Essai réel : NetFS rappelle sur la file donnée sans la retenir ; une file locale libérée plantait l'agent.
    func testTheRealMounterReportsAnUnreachableServerWithoutCrashing() async {
        let error = await NetFSShareMounter().mount("smb://invite@127.0.0.1:1/SyncMacPro-essai", timeout: 20)
        XCTAssertNotNil(error)
    }

    func testTheRealMounterSeesMountedVolumesWithoutTouchingThem() {
        XCTAssertTrue(NetFSShareMounter().isMounted("/"))
        XCTAssertFalse(NetFSShareMounter().isMounted("/Volumes/SyncMacPro-nexiste-pas"))
    }
}

final class NetworkShareAgentTests: XCTestCase {
    func shareTask(_ name: String, schedule: Schedule = .manual) -> SyncTask {
        SyncTask(name: name, source: .network(url: "smb://moi@nas/NAS", mountPath: "/Volumes/NAS/\(name)"),
                 destination: .local(path: "/copie/\(name)"), schedule: schedule)
    }

    func testAnUnavailableShareWaitsAndRetriesWithoutAFailure() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.configuration.shareRetryDelay = 300
        let task = shareTask("A")
        try h.save([task])
        h.factory.unavailableNames.set(["A"])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: task.id).count, 0, "pas d'échec dans l'historique")
        XCTAssertTrue(h.notifier.messages.get().isEmpty, "pas de notification d'échec")
        let state = await core.status().tasks.first { $0.id == task.id }?.state
        guard case .waiting(let reason) = state else { return XCTFail("en attente attendu : \(String(describing: state))") }
        XCTAssertTrue(reason.contains("« NAS » injoignable"), reason)
        XCTAssertTrue(reason.contains("nouvel essai à"), reason)

        h.clock.advance(290)
        await core.tick()
        XCTAssertEqual(h.factory.created, 1, "pas avant le délai")
        h.factory.unavailableNames.set([])
        h.clock.advance(20)
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 2, "nouvel essai après 5 min")
        let records = try h.history.list(taskID: task.id)
        XCTAssertEqual(records.map(\.status), [.succeeded])
    }

    func testAfterTheWaitLimitTheRunFailsForReal() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        h.configuration.shareRetryDelay = 300
        h.configuration.shareWaitLimit = 600
        let task = shareTask("A")
        try h.save([task])
        h.factory.unavailableNames.set(["A"])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        await h.step(core, minutes: 11)   // minute par minute, comme le minuteur de l'agent
        XCTAssertEqual(h.factory.created, 3)
        XCTAssertEqual(try h.history.list(taskID: task.id).map(\.status), [.failed])
        XCTAssertEqual(h.notifier.messages.get().count, 1)
    }

    func testAScheduledTaskWhoseShareIsNotMountedStartsSoTheShareGetsMounted() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = shareTask("A", schedule: .everyMinutes(60))
        try h.save([task])
        h.conditions.missingPaths.set(["/Volumes/NAS/A"])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        await core.waitForIdle()
        XCTAssertEqual(h.factory.created, 1, "le partage non monté n'empêche plus le départ : l'exécution le monte")
    }

    func testALocalFolderThatIsMissingStillWaits() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = SyncTask(name: "L", source: .local(path: "/absent"), destination: .local(path: "/copie"), schedule: .everyMinutes(60))
        try h.save([task])
        h.conditions.missingPaths.set(["/absent"])
        let core = h.makeCore()
        await core.start()
        await core.tick()
        XCTAssertEqual(h.factory.created, 0)
    }

    func testTheQueueMovesOnWhileAShareWaits() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let a = shareTask("A")
        let b = SyncTask(name: "B", source: .local(path: "/b"), destination: .local(path: "/copie/b"))
        try h.save([a, b])
        h.factory.unavailableNames.set(["A"])
        let core = h.makeCore()
        await core.start()
        try await core.enqueue(a.id)
        try await core.enqueue(b.id)
        await core.setQueueRunning(true)
        let bRan = await eventually { h.factory.runners.get().contains { $0.ranTasks.get().first?.name == "B" } }
        XCTAssertTrue(bRan)
        await core.waitForIdle()
        XCTAssertEqual(try h.history.list(taskID: a.id).count, 0)
    }
}
