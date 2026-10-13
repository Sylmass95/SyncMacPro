import XCTest
@testable import SyncKit

final class AgentProtocolTests: XCTestCase {
    func roundTrip(_ request: AgentRequest) throws -> AgentRequest {
        let data = try JSONEncoder().encode(AgentRequestEnvelope(version: agentProtocolVersion, request: request))
        return try JSONDecoder().decode(AgentRequestEnvelope.self, from: data).request
    }

    func testEveryRequestSurvivesEncoding() throws {
        let id = UUID()
        let requests: [AgentRequest] = [
            .status, .listTasks, .history(taskID: id, limit: 5), .history(taskID: nil, limit: 20),
            .runNow(id), .pause(id), .resume(id), .stop(id), .setGlobalPause(true), .approveDeletion(id), .reloadTasks,
            .saveTask(makeTask("x")), .removeTask(id),
        ]
        for request in requests { XCTAssertEqual(try roundTrip(request), request) }
    }

    func testResponsesSurviveEncoding() throws {
        let task = makeTask("a")
        let responses: [AgentResponse] = [
            .ok, .tasks([task]), .error(.versionMismatch(agent: 1, client: 2)), .error(.unknownTask),
            .error(.invalidTask("raison")), .error(.unknownRun),
            .status(AgentStatus(
                globalPause: true, stateRecovered: false, taskLoadError: nil,
                tasks: [AgentTaskInfo(id: task.id, name: "a", state: .waiting(reason: "réseau"))]
            )),
        ]
        for response in responses {
            let data = try JSONEncoder().encode(AgentResponseEnvelope(version: 1, response: response))
            XCTAssertEqual(try JSONDecoder().decode(AgentResponseEnvelope.self, from: data).response, response)
        }
    }

    func decode(_ data: Data) throws -> AgentResponseEnvelope {
        try JSONDecoder().decode(AgentResponseEnvelope.self, from: data)
    }

    func encode(version: Int, _ request: AgentRequest) throws -> Data {
        try JSONEncoder().encode(AgentRequestEnvelope(version: version, request: request))
    }

    func testRouterAnswersStatusAndCommands() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let task = makeTask(schedule: .manual)
        try h.save([task])
        let core = h.makeCore()
        await core.start()

        let status = try decode(await AgentRouter.handle(encode(version: agentProtocolVersion, .status), core: core))
        guard case .status(let info) = status.response else { return XCTFail("attendu : status") }
        XCTAssertEqual(info.tasks.map(\.name), ["tâche"])
        XCTAssertEqual(status.version, agentProtocolVersion)

        let ran = try decode(await AgentRouter.handle(encode(version: agentProtocolVersion, .runNow(task.id)), core: core))
        XCTAssertEqual(ran.response, .ok)
        await core.waitForIdle()
        let history = try decode(await AgentRouter.handle(encode(version: agentProtocolVersion, .history(taskID: task.id, limit: 5)), core: core))
        guard case .history(let records) = history.response else { return XCTFail("attendu : history") }
        XCTAssertEqual(records.map(\.status), [.succeeded])
    }

    func testRouterMapsAgentErrors() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        await core.start()
        let reply = try decode(await AgentRouter.handle(encode(version: agentProtocolVersion, .pause(UUID())), core: core))
        XCTAssertEqual(reply.response, .error(.notRunning))
    }

    func testRouterRejectsAnotherProtocolVersionWithoutReadingTheRequest() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        let futureRequest = Data(#"{"version":99,"request":{"quelqueChoseDeNouveau":{}}}"#.utf8)
        let reply = try decode(await AgentRouter.handle(futureRequest, core: core))
        XCTAssertEqual(reply.response, .error(.versionMismatch(agent: agentProtocolVersion, client: 99)))
    }

    func testRouterRejectsGarbage() async throws {
        let h = try AgentHarness(start: Date(timeIntervalSince1970: 0))
        let core = h.makeCore()
        let reply = try decode(await AgentRouter.handle(Data("pas du json".utf8), core: core))
        guard case .error(.internalFailure) = reply.response else { return XCTFail("attendu : erreur interne") }
    }
}
