import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class AgentModelRemotesTests: XCTestCase {
    func testReloadAndUsage() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([RemoteInfo(name: "Drive", type: "drive")]))
        agent.setTasks([SyncTask(name: "Photos", source: .local(path: "/a"), destination: .cloud(remote: "Drive", path: "p"))])
        agent.setStatus(.success(makeStatus()))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.refreshNow()
        await model.reloadRemotes()
        XCTAssertEqual(model.remotes.map(\.name), ["Drive"])
        XCTAssertNil(model.remotesError)
        XCTAssertEqual(model.tasks(usingRemote: "Drive").map(\.name), ["Photos"])
        XCTAssertTrue(model.tasks(usingRemote: "Autre").isEmpty)
        agent.setRemotes(.failure(AgentClientError.agent(.rcloneMissing)))
        await model.reloadRemotes()
        XCTAssertEqual(model.remotesError, AgentError.rcloneMissing.errorDescription)
    }

    func testConfigureMapsOutcomes() async {
        let agent = FakeAgent()
        let question = RemoteQuestion(state: "s", option: "config_is_local")
        agent.setConfigOutcomes([.success(.question(question)), .success(.done), .failure(AgentClientError.agent(.invalidRemote("refus")))])
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let step = RemoteConfigStep.start(name: "D", type: "dropbox", parameters: [:])
        let first = await model.configureRemote(step)
        XCTAssertEqual(first, .question(question))
        let second = await model.configureRemote(step)
        XCTAssertEqual(second, .done)
        let third = await model.configureRemote(step)
        XCTAssertEqual(third, .failed("refus"))
        XCTAssertEqual(agent.configured.count, 3)
    }

    func testDeleteReloadsAndReportsRefusal() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let ok = await model.deleteRemote("Drive")
        XCTAssertNil(ok)
        XCTAssertEqual(agent.performed.last, .deleteRemote("Drive"))
        agent.setPerformError(AgentClientError.agent(.remoteInUse(["Photos"])))
        let refused = await model.deleteRemote("Drive")
        XCTAssertEqual(refused, AgentError.remoteInUse(["Photos"]).errorDescription)
    }

    func testTestAndFolders() async {
        let agent = FakeAgent()
        agent.setRemoteTest(RemoteTestResult(ok: false, message: "jeton expiré"))
        agent.setFolders(.success(["A", "B"]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let test = await model.testRemote("Drive")
        XCTAssertEqual(test, RemoteTestResult(ok: false, message: "jeton expiré"))
        let folders = await model.remoteFolders(remote: "Drive", path: "Photos")
        XCTAssertEqual(folders, .loaded(["A", "B"]))
        XCTAssertEqual(agent.folderRequests, ["Drive:Photos"])
        agent.setFolders(.failure(AgentClientError.unreachable))
        let failed = await model.remoteFolders(remote: "Drive", path: "")
        guard case .failed = failed else { return XCTFail() }
    }

    func testCancelIsSent() async {
        let agent = FakeAgent()
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.cancelRemoteConfiguration("D")
        XCTAssertEqual(agent.performed.last, .cancelRemoteConfiguration("D"))
    }
}
