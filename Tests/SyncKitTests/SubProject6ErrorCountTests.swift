import XCTest
@testable import SyncKit

final class SubProject6ErrorCountTests: XCTestCase {
    // Journal réel de COMMONS 01 (15/10) : un seul incident, rapporté trois fois.
    func testOneRcloneIncidentCountsOnce() {
        let log = RunLog()
        log.addError("partial file rename failed: rename A.partial A: file busy")
        log.addError("Attempt 1/3 failed with 1 errors and: rename A.partial A: file busy")
        log.addError("partial file rename failed: rename A.partial A: file busy")
        XCTAssertEqual(log.errors, 1)
        XCTAssertEqual(log.mainError?.contains("partial file rename failed"), true, log.mainError ?? "")
    }

    func testDistinctErrorsAreAllCounted() {
        let log = RunLog()
        log.addError("rsync: send_files failed to open \"/a\": Permission denied (13)")
        log.addError("rsync: send_files failed to open \"/b\": Permission denied (13)")
        log.addError("Failed to copy with 2 errors: last error was: x")
        XCTAssertEqual(log.errors, 2)
    }
}
