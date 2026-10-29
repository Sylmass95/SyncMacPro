import XCTest
import SyncKit
@testable import SyncMacProUI

/// 1.8.10 : connexion « NAS (SMB direct) » dans l'assistant, pour lire les noms que le partage monté n'ouvre pas.
@MainActor
final class Wizard1810Tests: XCTestCase {
    func testTheNASIsConnectedWithAnAccountAndAPassword() async {
        let agent = FakeAgent()
        agent.setRemotes(.success([]))
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        await model.reloadRemotes()
        let wizard = WizardModel(model: model, localizer: Localizer(language: "fr"))
        wizard.choose(.smb)
        XCTAssertEqual(wizard.name, "NAS SMB direct", "1.8.11 : sans parenthèses, que rclone refuse")
        XCTAssertNil(wizard.nameProblem)
        XCTAssertFalse(CloudService.smb.usesBrowser)
        XCTAssertFalse(wizard.canContinue)
        wizard.smbHost = " 10.92.7.3 "
        wizard.smbUser = "sylvain.masson"
        XCTAssertFalse(wizard.canContinue, "mot de passe requis")
        wizard.smbPassword = "secret"
        XCTAssertTrue(wizard.canContinue)
        XCTAssertEqual(wizard.parameters, ["host": "10.92.7.3", "user": "sylvain.masson", "pass": "secret"])
        XCTAssertEqual(CloudService.forType("smb"), .smb)
    }

    func testThePasswordIsAlwaysObscuredByRclone() {
        let smb = RcloneConfigCommand.arguments(for: .start(name: "NAS", type: "smb", parameters: ["host": "h", "pass": "p"]), config: nil)
        XCTAssertTrue(smb.contains("--obscure"))
        XCTAssertLessThan(smb.firstIndex(of: "--obscure")!, smb.firstIndex(of: "--")!)
        let drive = RcloneConfigCommand.arguments(for: .start(name: "D", type: "drive", parameters: ["scope": "drive"]), config: nil)
        XCTAssertFalse(drive.contains("--obscure"))
    }

    func testTheProblemsFilterShowsUnreadableNamesAndDuplicates() {
        let rows = [RunDetailRow(action: .added, size: 1, path: "a"), RunDetailRow(action: .recovered, size: 2, path: "b"),
                    RunDetailRow(action: .unreadable, size: nil, path: "c"), RunDetailRow(action: .duplicate, size: nil, path: "d")]
        XCTAssertEqual(RunDetailsView.filtered(rows, filter: .problems, query: "").map(\.path), ["c", "d"])
        XCTAssertEqual(RunDetailsView.filtered(rows, filter: .copied, query: "").map(\.path), ["a", "b"])
        let details = RunDetails(rows: rows, totals: [.recovered: .init(count: 1, bytes: 2), .unreadable: .init(count: 1, bytes: 0),
                                                      .duplicate: .init(count: 1, bytes: 0)], truncated: false)
        let line = RunDetailsView.totalsLine(details, localizer: Localizer(language: "fr"))
        XCTAssertTrue(line.contains("1 récupéré(s) par la connexion directe"), line)
        XCTAssertTrue(line.contains("1 doublon(s) sur le NAS"), line)
    }
}
