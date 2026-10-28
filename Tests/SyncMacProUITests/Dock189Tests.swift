import AppKit
import XCTest
@testable import SyncMacProUI

/// 1.8.9 : SyncMacPro ne reste dans le Dock que tant qu'une de ses fenêtres est ouverte. Fermée ou réduite, il ne vit
/// plus que dans la barre de menus ; lancé à l'ouverture de session, il y démarre directement, sans fenêtre.
@MainActor
final class Dock189Tests: XCTestCase {
    private let main = DockPresence.WindowInfo(isVisible: true, isTitled: true, isPanel: false)

    func testAnOpenWindowKeepsTheDockIcon() {
        XCTAssertEqual(DockPresence.policy(for: [main]), .regular)
    }

    func testWithoutAnOpenWindowTheAppLivesInTheMenuBarOnly() {
        XCTAssertEqual(DockPresence.policy(for: []), .accessory)
        let hidden = DockPresence.WindowInfo(isVisible: false, isTitled: true, isPanel: false)
        XCTAssertEqual(DockPresence.policy(for: [hidden]), .accessory, "fenêtre fermée ou masquée")
    }

    func testTheMenuBarPanelAndTheMiniatureDoNotBringTheDockIconBack() {
        let menuBar = DockPresence.WindowInfo(isVisible: true, isTitled: false, isPanel: false)
        let miniature = DockPresence.WindowInfo(isVisible: true, isTitled: true, isPanel: true)
        XCTAssertEqual(DockPresence.policy(for: [menuBar, miniature]), .accessory)
    }

    func testALaunchAtLoginIsRecognised() {
        XCTAssertTrue(LaunchContext.isLoginLaunch(event: Self.openEvent(loginItem: true)))
        XCTAssertFalse(LaunchContext.isLoginLaunch(event: Self.openEvent(loginItem: false)), "ouverte à la main")
        XCTAssertFalse(LaunchContext.isLoginLaunch(event: nil))
    }

    func testOnlyTheFirstWindowOfALoginLaunchIsHidden() {
        let context = LaunchContext(atLogin: true)
        XCTAssertTrue(context.shouldHideFirstWindow())
        XCTAssertFalse(context.shouldHideFirstWindow(), "rouverte ensuite depuis la barre de menus : elle s'affiche")
        XCTAssertFalse(LaunchContext(atLogin: false).shouldHideFirstWindow())
    }

    private static func openEvent(loginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if loginItem {
            event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }
}
