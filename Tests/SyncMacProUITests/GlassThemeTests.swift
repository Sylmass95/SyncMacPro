import SwiftUI
import XCTest
@testable import SyncMacProUI

@MainActor
final class GlassThemeTests: XCTestCase {
    func testVividIsBolderThanSoft() {
        for scheme in [ColorScheme.light, .dark] {
            let vivid = GlassTheme(style: .vivid, scheme: scheme)
            let soft = GlassTheme(style: .soft, scheme: scheme)
            XCTAssertGreaterThan(vivid.blobs.map(\.opacity).reduce(0, +), soft.blobs.map(\.opacity).reduce(0, +))
            XCTAssertGreaterThan(vivid.progressGlow, soft.progressGlow)
            XCTAssertGreaterThan(vivid.buttonGlow, soft.buttonGlow)
            XCTAssertTrue(vivid.usesMaterial)
            XCTAssertEqual(vivid.blobs.count, 3, "A : trois taches de couleur")
        }
    }

    func testDarkDiffersFromLight() {
        XCTAssertNotEqual(GlassTheme(style: .vivid, scheme: .light), GlassTheme(style: .vivid, scheme: .dark))
        XCTAssertGreaterThan(GlassTheme(style: .vivid, scheme: .dark).shadowOpacity,
                             GlassTheme(style: .vivid, scheme: .light).shadowOpacity, "ombres plus fortes en sombre")
    }

    func testReducedTransparencyDropsGlassAndGlow() {
        let theme = GlassTheme(style: .vivid, scheme: .light, reduceTransparency: true)
        XCTAssertFalse(theme.usesMaterial)
        XCTAssertEqual(theme.progressGlow, 0)
        XCTAssertEqual(theme.buttonGlow, 0)
        XCTAssertEqual(theme.cardTintOpacity, 1, "carte opaque")
    }

    func testStyleIsStoredAndDefaultsToVivid() {
        XCTAssertEqual(GlassStyle.default, .vivid)
        XCTAssertEqual(GlassStyle(rawValue: "soft"), .soft)
        XCTAssertEqual(GlassStyle.storageKey, "glassStyle")
    }

    func testComponentsRenderInEveryStyleAndScheme() throws {
        for style in GlassStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let theme = GlassTheme(style: style, scheme: scheme)
                let view = ZStack(alignment: .topLeading) {
                    GlassBackdrop()
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Photos → NAS").font(.headline)
                            GlowProgressBar(value: 0.62)
                            Text("IMG_4821.HEIC · 41,2 Mo/s").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .glassCard()
                        HStack {
                            Button("Créer une tâche") {}.buttonStyle(GlassButtonStyle(prominent: false))
                            Button("Pause globale") {}.buttonStyle(GlassButtonStyle(prominent: true))
                        }
                    }
                    .padding(20)
                }
                .environment(\.glassTheme, theme)
                let name = "glass-\(style.rawValue)"
                assertNotBlank(try render(view, name: name, size: CGSize(width: 420, height: 220), scheme: scheme))
            }
        }
    }
}
