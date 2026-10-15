import XCTest
@testable import SyncKit

final class SubProject6TypesTests: XCTestCase {
    func testMbpsAreSpeedtestMegabits() {
        XCTAssertEqual(BandwidthRate.bytesPerSecond(mbps: 100), 12_500_000)
        XCTAssertEqual(BandwidthRate.bytesPerSecond(mbps: 0.5), 62_500)
    }

    // Un agent 1.2.x envoie des JSON sans les champs nouveaux : ils se lisent, les champs restent vides.
    func testOldJSONStillDecodes() throws {
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data(
            #"{"filesTransferred":1,"bytesTransferred":2,"deletions":0,"errors":0,"durationSeconds":3}"#.utf8))
        XCTAssertNil(summary.directories)
        XCTAssertNil(summary.averageSpeed)
        let status = try JSONDecoder().decode(AgentStatus.self, from: Data(
            #"{"globalPause":false,"stateRecovered":false,"tasks":[]}"#.utf8))
        XCTAssertNil(status.queue)
        XCTAssertNil(status.bandwidth)
        let progress = ProgressInfo(TransferSnapshot())
        let encoded = try JSONEncoder().encode(progress)
        XCTAssertEqual(try JSONDecoder().decode(ProgressInfo.self, from: encoded), progress)
    }

    func testProgressCarriesDirectoriesAndAverageSpeed() {
        var snapshot = TransferSnapshot()
        snapshot.dirsDone = 3
        snapshot.totalDirs = 9
        snapshot.averageSpeed = 25_000_000
        let info = ProgressInfo(snapshot)
        XCTAssertEqual(info.dirsDone, 3)
        XCTAssertEqual(info.totalDirs, 9)
        XCTAssertEqual(info.averageSpeed, 25_000_000)
    }

    func testNewRequestsRoundTrip() throws {
        let id = UUID()
        for request in [AgentRequest.enqueue(id), .dequeue(id), .moveInQueue(id, to: 2), .setQueueRunning(true),
                        .setBandwidth(BandwidthLimits(downloadMbps: 200, uploadMbps: 50, localMbps: nil))] {
            let data = try JSONEncoder().encode(AgentRequestEnvelope(request: request))
            XCTAssertEqual(try JSONDecoder().decode(AgentRequestEnvelope.self, from: data).request, request)
        }
    }
}
