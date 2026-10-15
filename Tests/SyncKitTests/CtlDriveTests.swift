import XCTest
@testable import SyncKit

/// `ctl` et le disque amovible (1.4.0).
final class CtlDriveTests: XCTestCase {
    func testEjectAndAbandonCommands() throws {
        XCTAssertEqual(try CtlParser.parse(["eject", "Sauvegarde"]).command, .eject("Sauvegarde"))
        XCTAssertEqual(try CtlParser.parse(["ejecter", "Sauvegarde"]).command, .eject("Sauvegarde"))
        XCTAssertEqual(try CtlParser.parse(["abandon", "Sauvegarde"]).command, .abandon("Sauvegarde"))
        XCTAssertEqual(try CtlParser.parse(["abandonner", "Sauvegarde"]).command, .abandon("Sauvegarde"))
        XCTAssertThrowsError(try CtlParser.parse(["eject"]))
        XCTAssertTrue(CtlParser.usage.contains("eject <tâche>"))
    }

    func testStatusLineOfASuspendedBackup() {
        let utc = TimeZone(identifier: "UTC")!
        let suspended = AgentTaskInfo(
            id: UUID(), name: "Sauvegarde", state: .waiting(reason: "disque débranché depuis 2 h"),
            driveSuspendedSince: Date(timeIntervalSince1970: 0), driveMounted: false
        )
        let lines = CtlFormatter.statusLines(
            AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [suspended]), timeZone: utc
        )
        XCTAssertTrue(lines[1].contains("en pause : disque débranché depuis 01/01 00:00"), lines[1])
        XCTAssertTrue(lines[1].contains("abandon"), "la commande pour repartir de zéro est rappelée : \(lines[1])")
    }
}
