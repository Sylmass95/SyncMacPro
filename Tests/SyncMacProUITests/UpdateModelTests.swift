import XCTest
@testable import SyncMacProUI

@MainActor
final class UpdateModelTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "maj-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    let releaseJSON = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/Sylmass95/SyncMacPro/releases/tag/v1.2.0","draft":false,"prerelease":false}"#.utf8)

    func testAutomaticCheckOncePerDay() async {
        let calls = Counter()
        let data = releaseJSON
        let store = defaults()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = UpdateModel(checker: UpdateChecker(current: "1.0.0") { _ in calls.increment(); return (data, 200) },
                                defaults: store, now: { now })
        XCTAssertTrue(model.automatic)
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(model.available?.version.description, "1.2.0")
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 1, "déjà vérifié aujourd'hui")
        now = now.addingTimeInterval(90_000)
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 2)
        model.automatic = false
        now = now.addingTimeInterval(90_000)
        await model.checkIfDue()
        XCTAssertEqual(calls.value, 2, "désactivé")
        await model.checkNow()
        XCTAssertEqual(calls.value, 3, "vérifier maintenant passe outre")
    }

    func testFailureIsSilentAutomaticallyButShownOnDemand() async {
        let model = UpdateModel(checker: UpdateChecker(current: "1.0.0") { _ in throw URLError(.timedOut) }, defaults: defaults())
        await model.checkIfDue()
        XCTAssertNil(model.available)
        guard case .failed = model.state else { return XCTFail() }
    }

    func testConcurrentChecksGiveOneAnswer() async {
        let calls = Counter()
        let gate = TestGate()
        let data = releaseJSON
        let model = UpdateModel(checker: UpdateChecker(current: "1.0.0") { _ in
            calls.increment()
            await gate.wait()
            return (data, 200)
        }, defaults: defaults())
        async let first: Void = model.checkNow()
        async let second: Void = model.checkNow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        gate.release()
        _ = await (first, second)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(model.available?.version.description, "1.2.0")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
