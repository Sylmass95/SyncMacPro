import SwiftUI
import XCTest
import SyncKit
@testable import SyncMacProUI

@MainActor
final class RemoteFolderPickerTests: XCTestCase {
    let fr = Localizer(language: "fr")

    func testPaths() {
        XCTAssertEqual(RemotePath.components("/Photos//2024/"), ["Photos", "2024"])
        XCTAssertEqual(RemotePath.join(["Photos", "2024"]), "Photos/2024")
        XCTAssertEqual(RemotePath.parent("Photos/2024"), "Photos")
        XCTAssertEqual(RemotePath.parent("Photos"), "")
        XCTAssertEqual(RemotePath.parent(""), "")
    }

    func testListingStatesRender() throws {
        let states: [FolderListing?] = [nil, .loaded(["2023", "2024"]), .loaded([]), .failed("jeton expiré")]
        for (index, state) in states.enumerated() {
            let view = RemoteFolderListBody(remote: "Drive", path: "Photos", listing: state, localizer: fr, onOpen: { _ in })
            assertNotBlank(try render(view, name: "remote-folders-\(index)", size: CGSize(width: 480, height: 220), scheme: .light))
        }
    }

    func testCloudSideRendersWithConnections() throws {
        var draft = TaskDraft()
        draft.destination.kind = .cloud
        draft.destination.remote = "Drive"
        draft.destination.path = "Sauvegardes"
        let context = RemoteContext(remotes: [RemoteInfo(name: "Drive", type: "drive")], onAdd: {}, browse: { _, _ in .loaded([]) })
        let view = EndpointsStepView(draft: .constant(draft), localizer: fr, remotes: context)
        assertNotBlank(try render(view, name: "editor-cloud-side", size: CGSize(width: 620, height: 300), scheme: .light))
    }
}
