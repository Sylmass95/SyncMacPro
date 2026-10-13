import XCTest
@testable import SyncKit

/// Défauts reportés par la relecture du sous-projet 4.
final class Fix120RemotesTests: XCTestCase {
    // Une réponse avec Error et une question : la question est reposée avec le message, la connexion n'est pas perdue.
    func testErrorWithAQuestionAsksAgain() throws {
        let reply = Data(#"{"State":"s2","Option":{"Name":"config_driveid","Type":"string"},"Error":"valeur refusée"}"#.utf8)
        guard case .question(let question) = try RcloneConfigReply.outcome(from: reply) else { return XCTFail() }
        XCTAssertEqual(question.option, "config_driveid")
        XCTAssertEqual(question.error, "valeur refusée")
    }

    // `--` avant les arguments positionnels : un nom ou une valeur commençant par « - » n'est jamais lu comme une option.
    func testPositionalArgumentsComeAfterDoubleDash() {
        let create = RcloneConfigCommand.arguments(for: .start(name: "Drive", type: "drive", parameters: ["scope": "drive"]), config: nil)
        XCTAssertEqual(create, ["config", "create", "--non-interactive", "--", "Drive", "drive", "scope=drive"])
        let answer = RcloneConfigCommand.arguments(for: .answer(name: "Drive", state: "s", result: "-x"), config: "/c")
        XCTAssertEqual(answer, ["config", "update", "--continue", "--state", "s", "--result", "-x", "--non-interactive", "--config", "/c", "--", "Drive"])
        XCTAssertEqual(RcloneConfigCommand.delete("Drive", config: nil), ["config", "delete", "--", "Drive"])
    }

    func testBadNamesAndMultilineValuesAreRefusedAtEveryStep() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let core = h.makeCore(remotes: remotes)
        for step in [RemoteConfigStep.answer(name: "-x", state: "s", result: "r"), .reconnect(name: "a:b"),
                     .answer(name: "Drive", state: "s", result: "ligne1\nligne2"),
                     .start(name: "Drive", type: "s3", parameters: ["secret_access_key": "a\nb"])] {
            do { _ = try await core.configureRemote(step); XCTFail("\(step)") } catch {
                guard case .invalidRemote = error as? AgentError else { return XCTFail("\(error)") }
            }
        }
        do { try await core.deleteRemote("--config=/etc/x"); XCTFail() } catch {
            guard case .invalidRemote = error as? AgentError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(remotes.steps.get().isEmpty)
        XCTAssertTrue(remotes.deleted.get().isEmpty)
    }

    // Une annulation reçue pendant la lecture de la liste (avant rclone) n'est pas perdue : rien n'est créé.
    func testCancelBeforeRcloneStartsIsKept() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let gate = TestGate()
        remotes.listGate.set(gate)
        let core = h.makeCore(remotes: remotes)
        let pending = Task { try await core.configureRemote(.start(name: "Dropbox", type: "dropbox", parameters: [:])) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await core.cancelRemoteConfiguration("Dropbox")
        gate.release()
        do { _ = try await pending.value; XCTFail("doit être annulée") } catch {
            XCTAssertEqual(error as? AgentError, .invalidRemote(RemoteConfigError.cancelled.errorDescription!))
        }
        XCTAssertTrue(remotes.steps.get().isEmpty, "rclone n'a pas été lancé")
    }

    // `ctl log` : une copie manuelle (sans tâche) se retrouve par son nom dans l'historique.
    func testLatestRunByName() {
        let a = RunRecord(taskID: UUID(), taskName: "Copie de f4.txt vers one", engine: .rsync, mode: .copy, startedAt: Date(timeIntervalSince1970: 10))
        let b = RunRecord(taskID: UUID(), taskName: "Copie de f4.txt vers one", engine: .rsync, mode: .copy, startedAt: Date(timeIntervalSince1970: 20))
        let c = RunRecord(taskID: UUID(), taskName: "Autre", engine: .rsync, mode: .copy, startedAt: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(TaskReference.latestRun(named: "copie de f4", in: [a, b, c])?.id, b.id)
        XCTAssertNil(TaskReference.latestRun(named: "inconnue", in: [a, b, c]))
    }

    // Relecture 1.2.0 : une annulation sans étape en cours ne doit pas tuer la prochaine configuration du même nom.
    func testCancelWithoutARunningStepLeavesNoPendingCancel() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let remotes = FakeRemotes()
        let core = h.makeCore(remotes: remotes)
        await core.cancelRemoteConfiguration("Dropbox")
        XCTAssertTrue(remotes.cancelled.get().isEmpty, "rien ne tourne : rien à annuler côté rclone")
    }

    // Une simulation d'un bidirectionnel en cours est refusée (elle déplacerait ses liens ; bisync la bloquerait).
    func testBisyncSimulationIsRefusedWhileItRuns() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0), gated: true)
        let task = makeTask("Bidir", schedule: .manual, mode: .bidirectional)
        try h.save([task])
        let core = h.makeCore()
        await core.start()
        try await core.runNow(task.id)
        _ = await eventually { h.factory.runners.get().count == 1 }
        do { _ = try await core.simulate(task); XCTFail() } catch {
            XCTAssertEqual(error as? AgentError, .alreadyRunning)
        }
        h.factory.runners.get().forEach { $0.release() }
        await core.waitForIdle()
    }
}
