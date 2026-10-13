import SwiftUI

/// Style de verre choisi dans les Réglages : Intense (inspiré de Rsync-GUI, par défaut) ou Léger.
public enum GlassStyle: String, CaseIterable, Sendable {
    case vivid, soft

    public static let `default` = GlassStyle.vivid
    public static let storageKey = "glassStyle"
}

/// Une tache de couleur du fond (dégradé radial).
public struct GlassBlob: Equatable, Sendable {
    public let color: Color
    public let center: UnitPoint
    /// Rayon, en fraction de la plus grande dimension de la vue.
    public let radius: CGFloat
    public let opacity: Double
}

/// Toutes les valeurs visuelles du thème verre, pour un style et une apparence. Une seule source pour toutes les vues.
public struct GlassTheme: Equatable, Sendable {
    public let backdropStops: [Color]
    public let blobs: [GlassBlob]
    /// Voile posé sur le matériau (blanc en clair, gris en sombre).
    public private(set) var cardTint: Color
    public private(set) var cardTintOpacity: Double
    public let borderOpacity: Double
    public let highlightOpacity: Double
    public let shadowOpacity: Double
    public let shadowRadius: CGFloat
    /// Rayon du halo des barres de progression et des boutons principaux (0 : aucun).
    public private(set) var progressGlow: CGFloat
    public private(set) var buttonGlow: CGFloat
    /// Faux avec « Réduire la transparence » : cartes opaques, pas de flou.
    public let usesMaterial: Bool

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }

    static let blue = rgb(10, 132, 255), violet = rgb(150, 90, 255), teal = rgb(48, 209, 160)

    public init(style: GlassStyle, scheme: ColorScheme, reduceTransparency: Bool = false) {
        let dark = scheme == .dark
        switch style {
        case .vivid:
            backdropStops = dark
                ? [Self.rgb(29, 32, 48), Self.rgb(36, 28, 51), Self.rgb(20, 38, 43)]
                : [Self.rgb(233, 238, 251), Self.rgb(246, 241, 251), Self.rgb(232, 244, 243)]
            blobs = [
                GlassBlob(color: Self.blue, center: UnitPoint(x: 0.12, y: 0.08), radius: 0.6, opacity: dark ? 0.26 : 0.22),
                GlassBlob(color: Self.violet, center: UnitPoint(x: 0.92, y: 0.22), radius: 0.5, opacity: dark ? 0.20 : 0.18),
                GlassBlob(color: Self.teal, center: UnitPoint(x: 0.6, y: 1.0), radius: 0.55, opacity: dark ? 0.16 : 0.16),
            ]
            cardTint = dark ? Self.rgb(58, 60, 70) : .white
            cardTintOpacity = dark ? 0.46 : 0.52
            borderOpacity = dark ? 0.10 : 0.60
            highlightOpacity = dark ? 0.10 : 0.75
            shadowOpacity = dark ? 0.35 : 0.10
            shadowRadius = 15
            progressGlow = 7
            buttonGlow = 9
        case .soft:
            backdropStops = dark
                ? [Self.rgb(26, 28, 37), Self.rgb(31, 27, 40), Self.rgb(22, 31, 34)]
                : [Self.rgb(238, 241, 248), Self.rgb(244, 242, 249), Self.rgb(237, 244, 243)]
            blobs = [
                GlassBlob(color: Self.blue, center: UnitPoint(x: 0.10, y: 0.05), radius: 0.55, opacity: dark ? 0.14 : 0.12),
                GlassBlob(color: Self.violet, center: UnitPoint(x: 0.95, y: 0.30), radius: 0.45, opacity: dark ? 0.10 : 0.09),
            ]
            cardTint = dark ? Self.rgb(52, 54, 62) : .white
            cardTintOpacity = dark ? 0.55 : 0.62
            borderOpacity = dark ? 0.09 : 0.55
            highlightOpacity = dark ? 0.09 : 0.70
            shadowOpacity = dark ? 0.30 : 0.07
            shadowRadius = 9
            progressGlow = 4
            buttonGlow = 0
        }
        if reduceTransparency {
            usesMaterial = false
            progressGlow = 0
            buttonGlow = 0
            cardTintOpacity = 1
            cardTint = dark ? Self.rgb(44, 45, 52) : .white
        } else {
            usesMaterial = true
        }
    }
}

private struct GlassThemeKey: EnvironmentKey {
    static let defaultValue = GlassTheme(style: .default, scheme: .light)
}

extension EnvironmentValues {
    public var glassTheme: GlassTheme {
        get { self[GlassThemeKey.self] }
        set { self[GlassThemeKey.self] = newValue }
    }
}

/// Calcule le thème à partir du style choisi, de l'apparence et de « Réduire la transparence ».
@MainActor
struct GlassThemed: ViewModifier {
    @AppStorage(GlassStyle.storageKey) private var styleRaw = GlassStyle.default.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.environment(\.glassTheme, GlassTheme(
            style: GlassStyle(rawValue: styleRaw) ?? .default, scheme: scheme, reduceTransparency: reduceTransparency
        ))
    }
}

@MainActor
extension View {
    public func glassThemed() -> some View { modifier(GlassThemed()) }
}
