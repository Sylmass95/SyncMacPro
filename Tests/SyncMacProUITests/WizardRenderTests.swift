import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class WizardRenderTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func wizard(_ configure: (WizardModel) -> Void) -> WizardModel {
        let model = AgentModel(agent: FakeAgent(), sleeper: ManualSleeper())
        let wizard = WizardModel(model: model, localizer: fr)
        configure(wizard)
        return wizard
    }

    func testEveryStepRenders() throws {
        let cases: [(String, WizardModel)] = [
            ("service", wizard { _ in }),
            ("drive-own", wizard { $0.choose(.drive) }),
            ("drive-shared", wizard { $0.choose(.drive); $0.ownClient = false }),
            ("s3", wizard { $0.choose(.s3); $0.s3Provider = .minio }),
            ("name", wizard { $0.choose(.dropbox); $0.next() }),
            ("connect", wizard { $0.choose(.dropbox); $0.next(); $0.next() }),
            ("test", wizard { $0.choose(.dropbox); $0.step = .test }),
            ("done", wizard { $0.choose(.dropbox); $0.step = .done }),
        ]
        for (name, wizard) in cases {
            let view = WizardStepContent(wizard: wizard, localizer: fr)
            assertNotBlank(try render(view, name: "wizard-\(name)", size: CGSize(width: 560, height: 420), scheme: .light))
        }
    }

    func testGenericQuestionRenders() throws {
        let view = WizardQuestionView(
            question: RemoteQuestion(state: "s", option: "config_driveid", help: "Choisissez le lecteur",
                                     choices: [RemoteChoice(value: "a", help: "OneDrive (personal)"), RemoteChoice(value: "b", help: "Documents")],
                                     exclusive: true),
            answer: .constant("a"), localizer: fr
        )
        assertNotBlank(try render(view, name: "wizard-question", size: CGSize(width: 520, height: 200), scheme: .light))
    }

    func testDriveGuideLinksToTheConsole() {
        XCTAssertEqual(ConnectionWizardView.googleConsoleURL.host, "console.cloud.google.com")
    }
}
