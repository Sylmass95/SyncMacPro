import XCTest
@testable import SyncKit

final class CtlQueueTests: XCTestCase {
    func parse(_ a: String...) throws -> CtlCommand { try CtlParser.parse(a).command }

    func testQueueCommands() throws {
        XCTAssertEqual(try parse("queue"), .queue)
        XCTAssertEqual(try parse("file"), .queue)
        XCTAssertEqual(try parse("queue", "add", "COMMONS", "05"), .queueAdd("COMMONS 05"))
        XCTAssertEqual(try parse("queue", "remove", "COMMONS 05"), .queueRemove("COMMONS 05"))
        XCTAssertEqual(try parse("queue", "up", "x"), .queueMove("x", up: true))
        XCTAssertEqual(try parse("queue", "down", "x"), .queueMove("x", up: false))
        XCTAssertEqual(try parse("queue", "start"), .queueRun(true))
        XCTAssertThrowsError(try parse("queue", "shuffle"))
        XCTAssertThrowsError(try parse("queue", "add"))
    }

    /// 1.7.0 : la liste est la file.
    func testForceParses() throws {
        XCTAssertEqual(try parse("force", "Mac", "PERSO"), .force("Mac PERSO"))
        XCTAssertEqual(try parse("forcer", "x"), .force("x"))
        XCTAssertThrowsError(try parse("force"))
    }

    func testQueueListsTheOrder() {
        let a = AgentTaskInfo(id: UUID(), name: "Nuit", state: .running)
        var b = AgentTaskInfo(id: UUID(), name: "QNAP", state: .queued)
        b.rank = 2
        b.waitReason = "même disque que « Nuit »"
        var first = a
        first.rank = 1
        let lines = CtlFormatter.orderLines(AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [first, b]))
        XCTAssertEqual(lines, ["1. Nuit — en cours", "2. QNAP — en file (même disque que « Nuit »)"])
    }

    func testQueueUpMovesOneRank() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(CtlFormatter.moved(ids[2], in: ids, up: true), [ids[0], ids[2], ids[1]])
        XCTAssertEqual(CtlFormatter.moved(ids[0], in: ids, up: true), ids)
        XCTAssertEqual(CtlFormatter.moved(ids[0], in: ids, up: false), [ids[1], ids[0], ids[2]])
    }

    func testQueueStartExplainsThereIsNothingToStart() {
        XCTAssertTrue(CtlFormatter.queueRunMessage.contains("La liste est la file"))
    }

    func testBandwidthCommands() throws {
        XCTAssertEqual(try parse("bandwidth"), .bandwidth)
        XCTAssertEqual(try parse("debit", "--down", "200", "--up", "off"), .setBandwidth(down: "200", up: "off", local: nil))
        XCTAssertEqual(try CtlParser.mbps("12,5"), 12.5)
        XCTAssertNil(try CtlParser.mbps("off"))
        XCTAssertThrowsError(try CtlParser.mbps("-3"))
    }
}
