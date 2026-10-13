import XCTest
@testable import SyncKit

final class AgentSystemTests: IntegrationTestCase {
    func testPathsLiveUnderTheRoot() {
        let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(paths.tasks.path, "/tmp/x/tasks.json")
        XCTAssertEqual(paths.state.path, "/tmp/x/scheduler-state.json")
        XCTAssertEqual(paths.history.path, "/tmp/x/history.sqlite")
        XCTAssertTrue(AgentPaths.standard.root.path.hasSuffix("Application Support/SyncMacPro"))
        XCTAssertTrue(AgentPaths.development.root.path.hasSuffix("Application Support/SyncMacPro-dev"))
    }

    func testReachabilityOfLocalFolders() throws {
        let conditions = MacSystemConditions()
        let folder = try folder("present")
        let file = try write(sandbox.appendingPathComponent("fichier.txt").path, "x")
        XCTAssertTrue(conditions.isReachable(.local(path: folder)))
        XCTAssertFalse(conditions.isReachable(.local(path: sandbox.appendingPathComponent("absent").path)))
        XCTAssertFalse(conditions.isReachable(.local(path: file)), "un fichier n'est pas un dossier")
        XCTAssertTrue(conditions.isReachable(.network(url: "smb://nas/partage", mountPath: folder)))
        XCTAssertFalse(conditions.isReachable(.network(url: "smb://nas/partage", mountPath: sandbox.appendingPathComponent("démonté").path)))
    }

    func testPowerAndNetworkQueriesDoNotCrash() {
        let conditions = MacSystemConditions()
        _ = conditions.isOnACPower()
        _ = conditions.isNetworkAvailable()
    }

    func testSleepActivityIsIdempotent() {
        let activity = SleepActivity()
        activity.begin(); activity.begin(); activity.end(); activity.end()
    }

    func testSigningRequirementNamesTheTeam() {
        XCTAssertEqual(
            CodeSigning.requirement(forTeam: "ABCDE12345"),
            #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
        )
        _ = CodeSigning.ownTeamIdentifier()   // nil pour un binaire ad hoc : ne doit pas planter
    }
}
