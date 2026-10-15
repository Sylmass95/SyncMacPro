import XCTest
@testable import SyncKit

final class RemovableDriveTypesTests: XCTestCase {
    let drive = RemovableDrive(volumeUUID: "1234-ABCD", volumeName: "Extreme Pro", relativePath: "Sauvegardes/Photos",
                               trigger: .atMostEveryDays(7), resumeWindowDays: 3, eject: .button)

    func testRoundTripAndOldTasksWithoutTheKey() throws {
        var task = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/Volumes/Extreme Pro/Sauvegardes/Photos"))
        task.removableDrive = drive
        XCTAssertEqual(try JSONDecoder().decode(SyncTask.self, from: JSONEncoder().encode(task)), task)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        old["removableDrive"] = nil
        let decoded = try JSONDecoder().decode(SyncTask.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.removableDrive)
    }

    func testDestinationFollowsTheMountPoint() {
        XCTAssertEqual(drive.destinationPath(mountPath: "/Volumes/Extreme Pro 1"), "/Volumes/Extreme Pro 1/Sauvegardes/Photos")
        var root = drive
        root.relativePath = ""
        XCTAssertEqual(root.destinationPath(mountPath: "/Volumes/X"), "/Volumes/X")
    }

    func testStateAndStatusFields() throws {
        var entry = TaskScheduleState(firstSeen: Date(timeIntervalSince1970: 0))
        entry.suspendedRun = SuspendedRun(recordID: UUID(), since: Date(timeIntervalSince1970: 10), summary: RunSummary(filesTransferred: 3))
        XCTAssertEqual(try JSONDecoder().decode(TaskScheduleState.self, from: JSONEncoder().encode(entry)), entry)
        let info = AgentTaskInfo(id: UUID(), name: "t", state: .idle, driveSuspendedSince: Date(), driveMounted: true)
        XCTAssertEqual(try JSONDecoder().decode(AgentTaskInfo.self, from: JSONEncoder().encode(info)), info)
        for request in [AgentRequest.abandonSuspended(UUID()), .ejectDrive(UUID())] {
            let data = try JSONEncoder().encode(AgentRequestEnvelope(request: request))
            XCTAssertEqual(try JSONDecoder().decode(AgentRequestEnvelope.self, from: data).request, request)
        }
    }
}
