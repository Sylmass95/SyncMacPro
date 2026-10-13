import SwiftUI
import SyncKit
import XCTest
@testable import SyncMacProUI

@MainActor
final class RunLogRenderTests: XCTestCase {
    func testEveryLogStateRenders() throws {
        let lines = (1...30).map { "[10:0\($0 % 10):00] >f+++++++++ Vacances/IMG_\($0).jpg" }.joined(separator: "\n")
        let states: [(String, LogOutcome?)] = [
            ("loading", nil),
            ("loaded", .loaded(RunLogText(text: lines, truncated: true))),
            ("missing", .missing),
            ("failed", .failed("L'agent ne répond pas.")),
        ]
        for (name, outcome) in states {
            let view = RunLogContent(outcome: outcome, localizer: Localizer(language: "fr")).padding(16)
            let image = try render(view, name: "log-\(name)", size: CGSize(width: 760, height: 420), scheme: .light)
            assertNotBlank(image)
        }
    }
}
