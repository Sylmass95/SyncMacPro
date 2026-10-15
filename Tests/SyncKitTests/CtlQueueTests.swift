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
        XCTAssertEqual(try parse("queue", "stop"), .queueRun(false))
        XCTAssertThrowsError(try parse("queue", "shuffle"))
        XCTAssertThrowsError(try parse("queue", "add"))
    }

    func testBandwidthCommands() throws {
        XCTAssertEqual(try parse("bandwidth"), .bandwidth)
        XCTAssertEqual(try parse("debit", "--down", "200", "--up", "off"), .setBandwidth(down: "200", up: "off", local: nil))
        XCTAssertEqual(try CtlParser.mbps("12,5"), 12.5)
        XCTAssertNil(try CtlParser.mbps("off"))
        XCTAssertThrowsError(try CtlParser.mbps("-3"))
    }
}
