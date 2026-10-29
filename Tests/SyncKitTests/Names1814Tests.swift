import XCTest
@testable import SyncKit

/// 1.8.14 : un fichier au nom mal enregistré déjà présent à la destination n'échoue pas à la copie mais à la
/// comparaison : rclone veut relire la source pour calculer son empreinte (essai réel du 29/10 : 2 vidéos de
/// « Anim-multidevices », restées en échec après le rattrapage des 47 autres).
final class Names1814Tests: XCTestCase {
    func testAnUnreadableNameAtTheHashStepIsRecognised() {
        let path = "COMMONS/Enregistrement de l\u{2019}e\u{301}cran a\u{300} 15.35.47.mov"
        let line = #"{"level":"error","msg":"Failed to calculate src hash: hash: failed to open: open /Volumes/03_ARCHIVES_GLOBALES/\#(path): no such file or directory","object":"\#(path)","objectType":"*local.Object"}"#
        XCTAssertEqual(SourceNameIssue.parse(rcloneLine: line), .unreadable(path))
        let otherHashError = #"{"level":"error","msg":"Failed to calculate src hash: hash: input/output error","object":"a.mov"}"#
        XCTAssertNil(SourceNameIssue.parse(rcloneLine: otherHashError))
    }
}
