import SwiftUI

/// Apparence choisie dans les Réglages (clé `appearance` de `UserDefaults`).
public enum Appearance: String, CaseIterable, Sendable {
    case auto, light, dark

    public var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
