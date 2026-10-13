import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class WizardModelTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func make(_ agent: FakeAgent, remotes: [RemoteInfo] = []) async -> WizardModel {
        agent.setRemotes(.success(remotes))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.reloadRemotes()
        return WizardModel(model: model, localizer: fr)
    }

    func q(_ option: String, state: String = "s") -> RemoteQuestion { RemoteQuestion(state: state, option: option) }

    func testCatalog() {
        XCTAssertEqual(CloudService.drive.rcloneType, "drive")
        XCTAssertEqual(CloudService.forType("onedrive"), .onedrive)
        XCTAssertNil(CloudService.forType("alias"))
        XCTAssertFalse(CloudService.s3.usesBrowser)
        XCTAssertEqual(CloudService.autoAnswer(option: "config_shared_client_id"), "true")
        XCTAssertEqual(CloudService.autoAnswer(option: "config_is_local"), "true")
        XCTAssertEqual(CloudService.autoAnswer(option: "config_change_team_drive"), "false")
        XCTAssertNil(CloudService.autoAnswer(option: "config_driveid"))
        XCTAssertFalse(S3Provider.aws.needsEndpoint)
        XCTAssertTrue(S3Provider.minio.needsEndpoint)
    }

    func testDriveFlowAnswersKnownQuestionsAlone() async {
        let agent = FakeAgent()
        let wizard = await make(agent, remotes: [RemoteInfo(name: "Google Drive", type: "drive")])
        wizard.choose(.drive)
        XCTAssertEqual(wizard.step, .prepare)
        XCTAssertEqual(wizard.name, "Google Drive 2", "nom proposé, libre")
        XCTAssertFalse(wizard.canContinue, "identifiant propre par défaut : ID et secret requis")
        wizard.clientID = "123.apps.googleusercontent.com"
        wizard.clientSecret = "secret"
        XCTAssertTrue(wizard.canContinue)
        wizard.next()
        XCTAssertEqual(wizard.step, .name)
        wizard.next()
        XCTAssertEqual(wizard.step, .connect)
        agent.setConfigOutcomes([
            .success(.question(q("config_is_local", state: "a"))),
            .success(.question(q("config_change_team_drive", state: "b"))),
            .success(.done),
        ])
        agent.setRemoteTest(RemoteTestResult(ok: true))
        await wizard.connect()
        XCTAssertEqual(agent.configured, [
            .start(name: "Google Drive 2", type: "drive", parameters: [
                "scope": "drive", "client_id": "123.apps.googleusercontent.com", "client_secret": "secret",
            ]),
            .answer(name: "Google Drive 2", state: "a", result: "true"),
            .answer(name: "Google Drive 2", state: "b", result: "false"),
        ])
        XCTAssertEqual(wizard.step, .done)
        XCTAssertEqual(wizard.testResult?.ok, true)
    }

    func testSharedDriveClientNeedsNothing() async {
        let wizard = await make(FakeAgent())
        wizard.choose(.drive)
        wizard.ownClient = false
        XCTAssertTrue(wizard.canContinue)
        XCTAssertEqual(wizard.parameters, ["scope": "drive"])
    }

    func testUnknownQuestionIsAskedThenAnswered() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.onedrive)
        wizard.next(); wizard.next()
        let drives = RemoteQuestion(state: "c", option: "config_driveid", defaultValue: "id1",
                                    choices: [RemoteChoice(value: "id1", help: "OneDrive (personal)")], exclusive: true)
        agent.setConfigOutcomes([.success(.question(q("config_is_local", state: "a"))), .success(.question(drives))])
        await wizard.connect()
        XCTAssertEqual(wizard.question, drives)
        XCTAssertEqual(wizard.answer, "id1", "la valeur par défaut est proposée")
        XCTAssertEqual(wizard.step, .connect)
        agent.setConfigOutcomes([.success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: true))
        await wizard.submitAnswer()
        XCTAssertEqual(agent.configured.last, .answer(name: wizard.name, state: "c", result: "id1"))
        XCTAssertEqual(wizard.step, .done)
    }

    func testS3Parameters() async {
        let wizard = await make(FakeAgent())
        wizard.choose(.s3)
        XCTAssertFalse(wizard.canContinue)
        wizard.accessKey = "AK"
        wizard.secretKey = "SK"
        wizard.region = "eu-west-3"
        XCTAssertTrue(wizard.canContinue)
        XCTAssertEqual(wizard.parameters, ["provider": "AWS", "env_auth": "false", "access_key_id": "AK",
                                           "secret_access_key": "SK", "region": "eu-west-3"])
        wizard.s3Provider = .minio
        XCTAssertFalse(wizard.canContinue, "adresse du service requise")
        wizard.endpoint = "https://minio.local:9000"
        XCTAssertEqual(wizard.parameters["endpoint"], "https://minio.local:9000")
        XCTAssertEqual(wizard.parameters["provider"], "Minio")
    }

    func testNameProblems() async {
        let wizard = await make(FakeAgent(), remotes: [RemoteInfo(name: "nas", type: "smb")])
        wizard.choose(.dropbox)
        wizard.next()
        wizard.name = "NAS"
        XCTAssertEqual(wizard.nameProblem, .taken)
        XCTAssertFalse(wizard.canContinue)
        wizard.name = "Mon Dropbox"
        XCTAssertTrue(wizard.canContinue)
    }

    func testFailureIsShownAndCanBeRetried() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.dropbox)
        wizard.next(); wizard.next()
        agent.setConfigOutcomes([.failure(AgentClientError.agent(.invalidRemote("Accès refusé.")))])
        await wizard.connect()
        XCTAssertEqual(wizard.error, "Accès refusé.")
        XCTAssertEqual(wizard.step, .connect)
        XCTAssertFalse(wizard.busy)
    }

    func testFailedTestOffersFixOrKeep() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.s3)
        wizard.accessKey = "AK"; wizard.secretKey = "faux"; wizard.region = "eu-west-3"
        wizard.next(); wizard.next()
        agent.setConfigOutcomes([.success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: false, message: "InvalidAccessKeyId"))
        await wizard.connect()
        XCTAssertEqual(wizard.step, .test)
        XCTAssertEqual(wizard.testResult?.message, "InvalidAccessKeyId")
        await wizard.fix()
        XCTAssertEqual(agent.performed.last, .deleteRemote(wizard.name))
        XCTAssertEqual(wizard.step, .prepare)
        agent.setConfigOutcomes([.success(.done)])
        wizard.next(); wizard.next()
        await wizard.connect()
        wizard.keepAnyway()
        XCTAssertEqual(wizard.step, .done)
    }

    func testCancelDuringTheBrowserWait() async {
        let agent = FakeAgent()
        let wizard = await make(agent)
        wizard.choose(.dropbox)
        wizard.next(); wizard.next()
        let gate = TestGate()
        agent.holdConfiguration = gate
        agent.setConfigOutcomes([.success(.question(q("config_is_local"))), .failure(AgentClientError.agent(.invalidRemote("Configuration annulée.")))])
        let pending = Task { await wizard.connect() }
        _ = await eventually { wizard.waitingForBrowser }
        await wizard.cancel()
        XCTAssertEqual(agent.performed.last, .cancelRemoteConfiguration(wizard.name))
        gate.release()
        await pending.value
        XCTAssertFalse(wizard.waitingForBrowser)
        XCTAssertNil(wizard.error, "une annulation voulue n'est pas une erreur")
    }

    func testReconnect() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([RemoteInfo(name: "Drive", type: "drive")]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let wizard = WizardModel(reconnecting: RemoteInfo(name: "Drive", type: "drive"), model: model, localizer: fr)
        XCTAssertEqual(wizard.step, .connect)
        agent.setConfigOutcomes([.success(.question(q("config_is_local"))), .success(.done)])
        agent.setRemoteTest(RemoteTestResult(ok: true))
        await wizard.connect()
        XCTAssertEqual(agent.configured.first, .reconnect(name: "Drive"))
        XCTAssertEqual(wizard.step, .done)
    }
}
