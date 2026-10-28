import XCTest
@testable import SyncKit

/// 1.8.8 : Google Drive n'accepte qu'environ 750 Go envoyés par 24 h et par compte. Le 28/10, après 706 Go la veille,
/// rclone a réessayé dans le vide de 02 h 45 à 07 h 18 (889 refus « User rate limit exceeded »). Le quota d'une tâche
/// vaut désormais pour 24 h glissantes et pour toutes les tâches du même compte ; un refus de Google arrête la copie
/// et la tâche attend.
private let gib: Int64 = 1 << 30

private func driveTask(_ name: String, quota: Int? = 700, remote: String = "Drive,team_drive=X") -> SyncTask {
    var task = SyncTask(name: name, source: .local(path: "/source/\(name)"), destination: .cloud(remote: remote, path: name),
                        schedule: .everyMinutes(1))
    task.options.maxTransferGB = quota
    return task
}

final class UploadBudget188Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testTheAccountIsTheRemoteWithoutItsParameters() {
        XCTAssertEqual(CloudUploadBudget.account(for: driveTask("A")), "Drive")
        XCTAssertEqual(CloudUploadBudget.account(for: driveTask("B", remote: "Drive")), "Drive")
    }

    func testOnlyUploadsWithAQuotaCount() {
        XCTAssertNil(CloudUploadBudget.account(for: driveTask("A", quota: nil)), "pas de quota choisi : pas de budget")
        var download = driveTask("B")
        download.source = .cloud(remote: "Drive", path: "x")
        download.destination = .local(path: "/copie")
        XCTAssertNil(CloudUploadBudget.account(for: download), "une réception ne compte pas")
        var verify = driveTask("C")
        verify.mode = .verify
        XCTAssertNil(CloudUploadBudget.account(for: verify))
        var bisync = download
        bisync.mode = .bidirectional
        XCTAssertEqual(CloudUploadBudget.account(for: bisync), "Drive", "bisync envoie aussi vers le Drive")
    }

    func testRemainingSubtractsTheLast24Hours() {
        var account = CloudAccountState()
        account.uploads = [CloudUpload(at: now.addingTimeInterval(-25 * 3600), bytes: 600 * gib),   // sorti de la fenêtre
                           CloudUpload(at: now.addingTimeInterval(-3600), bytes: 500 * gib)]
        XCTAssertEqual(CloudUploadBudget.remainingGB(quotaGB: 700, account: account, inFlight: 0, now: now), 200)
        XCTAssertEqual(CloudUploadBudget.remainingGB(quotaGB: 700, account: account, inFlight: 50 * gib, now: now), 150)
        XCTAssertEqual(CloudUploadBudget.remainingGB(quotaGB: 400, account: account, inFlight: 0, now: now), 0)
    }

    func testFreeAtIsWhenEnoughOfTheWindowExpires() {
        var account = CloudAccountState()
        let first = now.addingTimeInterval(-10 * 3600), second = now.addingTimeInterval(-2 * 3600)
        account.uploads = [CloudUpload(at: first, bytes: 400 * gib), CloudUpload(at: second, bytes: 300 * gib)]
        XCTAssertEqual(CloudUploadBudget.freeAt(quotaGB: 700, account: account, inFlight: 0, now: now),
                       first.addingTimeInterval(86_400), "il faut que les 400 Go du premier envoi sortent de la fenêtre")
        XCTAssertNil(CloudUploadBudget.freeAt(quotaGB: 800, account: account, inFlight: 0, now: now), "100 Go libres")
    }

    func testARefusalByTheServiceHoldsTheAccount() {
        var account = CloudAccountState()
        account.blockedUntil = now.addingTimeInterval(3600)
        XCTAssertEqual(CloudUploadBudget.freeAt(quotaGB: 700, account: account, inFlight: 0, now: now), now.addingTimeInterval(3600))
        XCTAssertEqual(CloudUploadBudget.remainingGB(quotaGB: 700, account: account, inFlight: 0, now: now), 0)
        XCTAssertNil(CloudUploadBudget.freeAt(quotaGB: 700, account: account, inFlight: 0, now: now.addingTimeInterval(3601)))
    }

    func testOldStateWithoutAccountsStillDecodes() throws {
        let data = Data(#"{"paused":false,"tasks":{}}"#.utf8)
        let state = try JSONDecoder().decode(SchedulerState.self, from: data)
        XCTAssertEqual(state.cloudAccounts, [:])
    }
}

final class UploadSignal188Tests: XCTestCase {
    func testGoogleRefusalsAreRecognised() {
        let refusal = #"{"level":"error","msg":"Failed to copy: googleapi: Error 403: User rate limit exceeded., userRateLimitExceeded","object":"a.png"}"#
        XCTAssertEqual(OutputSignal.detect(in: refusal), .uploadLimit)
        XCTAssertEqual(OutputSignal.detect(in: #"{"level":"error","msg":"Received upload limit error: googleapi: Error 403"}"#), .uploadLimit)
        XCTAssertNil(OutputSignal.detect(in: #"{"level":"info","msg":"Copied (new)","object":"a.png"}"#))
    }

    func testUploadsToTheCloudStopOnTheUploadLimit() throws {
        let up = try RcloneCommandBuilder.command(for: driveTask("A"), run: RunOptions(archiveStamp: "s"))
        XCTAssertTrue(up.arguments.contains("--drive-stop-on-upload-limit"))
        let local = SyncTask(name: "L", source: .local(path: "/a"), destination: .local(path: "/b"),
                             options: TaskOptions(excludes: [], forcedEngine: .rclone))
        XCTAssertFalse(try RcloneCommandBuilder.command(for: local, run: RunOptions(archiveStamp: "s")).arguments.contains("--drive-stop-on-upload-limit"))
    }
}

final class UploadRunner188Tests: IntegrationTestCase {
    /// rclone n'a pas toujours reconnu le refus (message non documenté) : il réessaie sans fin. Le runner l'arrête.
    func testRepeatedRefusalsStopTheCopy() async throws {
        let fake = sandbox.appendingPathComponent("fake-rclone").path
        let line = #"{"level":"error","msg":"Failed to copy: googleapi: Error 403: User rate limit exceeded., userRateLimitExceeded","object":"a.png"}"#
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "--dry-run" ] && exit 0; done
        [ "$1" = "copy" ] || exit 0
        i=0
        while [ $i -lt 40 ]; do echo '\(line)' >&2; i=$((i+1)); sleep 0.2; done
        exit 0
        """.write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        let runner = TaskRunner(configuration: RunnerConfiguration(rclonePath: fake, workDirectory: sandbox.appendingPathComponent("w")))
        var task = driveTask("A")
        task.source = .local(path: try folder("s"))
        let started = Date()
        let result = try await runner.run(task)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "arrêtée sans attendre la fin des essais")
        XCTAssertEqual(result.status, .quotaReached)
        XCTAssertTrue(result.uploadLimitReached)
        XCTAssertTrue(result.summary.message?.contains("750") == true, result.summary.message ?? "")
    }
}

final class UploadAgent188Tests: XCTestCase {
    func makeHarness() throws -> AgentHarness {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 1_000_000))
        h.configuration.openApp = {}
        return h
    }

    func testUploadsAreCountedAndTheNextRunIsCapped() async throws {
        let h = try makeHarness()
        let first = driveTask("A"), second = driveTask("B")
        try h.save([first, second])
        h.factory.bytes.set(500 * gib)
        let core = h.makeCore()
        await core.start()
        try await core.runNow(first.id)
        await core.waitForIdle()
        try await core.runNow(second.id)
        await core.waitForIdle()
        let ran = h.factory.runners.get().flatMap { $0.ranTasks.get() }
        XCTAssertEqual(ran.map(\.options.maxTransferGB), [700, 200], "B n'a droit qu'au reste du compte")
    }

    func testAnExhaustedAccountMakesTheTaskWaitUntilTheWindowFrees() async throws {
        let h = try makeHarness()
        let first = driveTask("A"), second = driveTask("B")
        try h.save([first, second])
        h.factory.bytes.set(700 * gib)
        let core = h.makeCore()
        await core.start()
        try await core.runNow(first.id)
        await core.waitForIdle()
        let before = h.factory.created
        h.factory.bytes.set(0)
        await h.step(core, minutes: 3)
        XCTAssertEqual(h.factory.created, before, "rien ne part sur un compte épuisé")
        let state = await core.status().tasks.first { $0.id == second.id }?.state
        guard case .waiting(let reason) = state else { return XCTFail("en attente attendu, pas \(String(describing: state))") }
        XCTAssertTrue(reason.contains("quota d'envoi"), reason)
        h.clock.advance(86_400)
        await h.step(core, minutes: 2)
        XCTAssertGreaterThan(h.factory.created, before, "fenêtre libérée : la copie repart")
    }

    func testARefusalWaitsThreeHoursWithoutCountingAsAFailure() async throws {
        let h = try makeHarness()
        let task = driveTask("A")
        try h.save([task])
        h.factory.status.set(.quotaReached)
        h.factory.uploadLimit.set(true)
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        XCTAssertEqual(h.notifier.messages.get().count, 1, "le premier refus est signalé")
        await h.step(core, minutes: 60)
        XCTAssertEqual(h.factory.created, 1, "pas de nouvel essai avant 3 h")
        h.clock.advance(3 * 3600)
        await h.step(core, minutes: 2)
        XCTAssertEqual(h.factory.created, 2)
        XCTAssertEqual(h.notifier.messages.get().count, 1, "un refus répété (rien d'envoyé) n'est pas renotifié")
        let entry = await core.state.tasks[task.id.uuidString]
        XCTAssertEqual(entry?.attempts, 0, "pas un échec : les essais ne s'épuisent pas")
    }

    func testAManualRunOnAnExhaustedAccountKeepsTheTaskQuota() async throws {
        let h = try makeHarness()
        let task = driveTask("A")
        try h.save([task])
        h.factory.bytes.set(700 * gib)
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        await core.waitForIdle()
        try await core.runNow(task.id)
        await core.waitForIdle()
        let ran = h.factory.runners.get().flatMap { $0.ranTasks.get() }
        XCTAssertEqual(ran.last?.options.maxTransferGB, 700, "lancée à la main : jamais « 0 Go » (rclone l'ignorerait)")
    }
}
