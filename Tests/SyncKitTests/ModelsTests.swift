import XCTest
@testable import SyncKit

final class ModelsTests: XCTestCase {
    func testTaskSurvivesJSONRoundTrip() throws {
        let task = SyncTask(
            name: "Sauvegarde NAS",
            source: .network(url: "smb://nas/archives", mountPath: "/Volumes/archives"),
            destination: .cloud(remote: "gdrive", path: "BACKUP"),
            mode: .mirror,
            options: TaskOptions(bandwidthLimitKBps: 5000, deleteThresholdPercent: 10),
            schedule: .weekdays(days: [2, 3, 4], hour: 12, minute: 30)
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(SyncTask.self, from: data)
        XCTAssertEqual(decoded, task)
    }

    func testDefaultsAreSafe() {
        let task = SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))
        XCTAssertEqual(task.mode, .copy)
        XCTAssertEqual(task.schedule, .manual)
        XCTAssertEqual(task.options.deleteThresholdPercent, 25)
        XCTAssertEqual(task.options.archiveFolder, "_ARCHIVE")
        XCTAssertTrue(task.options.excludes.contains(".DS_Store"))
        XCTAssertTrue(task.sourceItems.isEmpty)
    }

    func testEndpointSpecsAndPaths() {
        XCTAssertEqual(Endpoint.local(path: "/a/b").rcloneSpec, "/a/b")
        XCTAssertEqual(Endpoint.cloud(remote: "gdrive", path: "X/Y").rcloneSpec, "gdrive:X/Y")
        XCTAssertEqual(Endpoint.network(url: "smb://n/s", mountPath: "/Volumes/s").filesystemPath, "/Volumes/s")
        XCTAssertNil(Endpoint.cloud(remote: "gdrive", path: "").filesystemPath)
        XCTAssertTrue(Endpoint.cloud(remote: "gdrive", path: "").isCloud)
        XCTAssertFalse(Endpoint.local(path: "/a").isCloud)
    }

    func testAppendingHandlesSlashes() {
        XCTAssertEqual(Endpoint.local(path: "/a/").appending("_ARCHIVE"), .local(path: "/a/_ARCHIVE"))
        XCTAssertEqual(Endpoint.cloud(remote: "g", path: "").appending("_ARCHIVE"), .cloud(remote: "g", path: "_ARCHIVE"))
        XCTAssertEqual(Endpoint.cloud(remote: "g", path: "X").appending("/Y"), .cloud(remote: "g", path: "X/Y"))
    }

    func testModeProperties() {
        XCTAssertTrue(SyncMode.mirror.deletesData)
        XCTAssertTrue(SyncMode.bidirectional.deletesData)
        XCTAssertTrue(SyncMode.move.deletesData)
        XCTAssertFalse(SyncMode.copy.deletesData)
        XCTAssertFalse(SyncMode.verify.deletesData)
        XCTAssertTrue(SyncMode.bidirectional.requiresRclone)
        XCTAssertTrue(SyncMode.versioned.requiresRclone)
        XCTAssertFalse(SyncMode.mirror.requiresRclone)
    }
}

final class TaskConditionsTests: XCTestCase {
    func testHourRangeWithinTheDay() {
        let range = HourRange(start: 9, end: 17)
        XCTAssertTrue(range.contains(hour: 9))
        XCTAssertTrue(range.contains(hour: 16))
        XCTAssertFalse(range.contains(hour: 17))
        XCTAssertFalse(range.contains(hour: 3))
    }

    func testHourRangeAcrossMidnight() {
        let range = HourRange(start: 22, end: 6)
        XCTAssertTrue(range.contains(hour: 23))
        XCTAssertTrue(range.contains(hour: 2))
        XCTAssertFalse(range.contains(hour: 6))
        XCTAssertFalse(range.contains(hour: 12))
    }

    func testEqualBoundsMeanWholeDay() {
        XCTAssertTrue(HourRange(start: 5, end: 5).contains(hour: 14))
    }

    func testTaskWithoutConditionsKeyStillDecodes() throws {
        let task = SyncTask(name: "ancienne", source: .local(path: "/a"), destination: .local(path: "/b"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "conditions")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SyncTask.self, from: legacy)
        XCTAssertEqual(decoded.name, "ancienne")
        XCTAssertEqual(decoded.conditions, TaskConditions())
    }

    func testConditionsSurviveEncoding() throws {
        var task = SyncTask(name: "nuit", source: .local(path: "/a"), destination: .local(path: "/b"))
        task.conditions = TaskConditions(requiresACPower: true, requiresNetwork: true, allowedHours: HourRange(start: 22, end: 6))
        let decoded = try JSONDecoder().decode(SyncTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
    }
}
