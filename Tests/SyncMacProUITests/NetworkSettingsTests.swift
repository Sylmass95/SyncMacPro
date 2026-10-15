import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

@MainActor
final class NetworkSettingsTests: XCTestCase {
    func testDraftParsesMegabitsWithCommaAndOffSwitches() {
        var draft = BandwidthDraft(BandwidthLimits(downloadMbps: 200, uploadMbps: nil, localMbps: 950))
        XCTAssertEqual(draft.downloadText, "200")
        XCTAssertTrue(draft.downloadOn)
        XCTAssertFalse(draft.uploadOn)
        draft.uploadOn = true
        draft.uploadText = "12,5"
        draft.localOn = false
        XCTAssertEqual(draft.limits, BandwidthLimits(downloadMbps: 200, uploadMbps: 12.5, localMbps: nil))
        draft.uploadText = "abc"
        XCTAssertNil(draft.limits, "valeur invalide : rien n'est envoyé")
        XCTAssertEqual(BandwidthDraft(BandwidthLimits(uploadMbps: 12.5)).uploadText, "12,5")
    }

    func testSectionRenders() throws {
        let model = AgentModel.preview(status: AgentStatus(globalPause: false, stateRecovered: false, taskLoadError: nil, tasks: [],
                                                           bandwidth: BandwidthLimits(downloadMbps: 200, localMbps: 950)))
        for scheme in [ColorScheme.light, .dark] {
            _ = try render(Form { NetworkSettingsSection(model: model, localizer: Localizer(language: "fr")) }.formStyle(.grouped).glassThemed(),
                           name: "reglages-reseau", size: CGSize(width: 560, height: 360), scheme: scheme)
        }
    }
}
