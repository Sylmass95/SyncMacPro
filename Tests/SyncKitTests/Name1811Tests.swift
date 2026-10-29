import XCTest
@testable import SyncKit

/// 1.8.11 : l'assistant proposait « NAS (SMB direct) », que rclone refuse (parenthèses) : « Suivant » restait grisé.
final class Name1811Tests: XCTestCase {
    func testTheSuggestedNameIsAlwaysAccepted() {
        XCTAssertEqual(RemoteNameRule.suggestion("NAS (SMB direct)", existing: []), "NAS SMB direct")
        XCTAssertEqual(RemoteNameRule.suggestion("NAS (SMB direct)", existing: ["NAS SMB direct"]), "NAS SMB direct 2")
        XCTAssertEqual(RemoteNameRule.suggestion("Google Drive", existing: []), "Google Drive")
        for base in ["NAS (SMB direct)", "Amazon S3", " -bizarre/ nom: ", "()"] {
            let name = RemoteNameRule.suggestion(base, existing: [])
            XCTAssertNil(RemoteNameRule.problem(name, existing: []), "« \(name) » refusé")
        }
    }
}
