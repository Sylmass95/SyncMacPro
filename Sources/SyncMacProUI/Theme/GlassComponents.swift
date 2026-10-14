import SwiftUI

/// Le fond coloré derrière le verre : dégradé de base et taches de couleur.
@MainActor
public struct GlassBackdrop: View {
    @Environment(\.glassTheme) private var theme

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let size = max(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(colors: theme.backdropStops, startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(Array(theme.blobs.enumerated()), id: \.offset) { _, blob in
                    RadialGradient(
                        colors: [blob.color.opacity(blob.opacity), blob.color.opacity(0)],
                        center: blob.center, startRadius: 0, endRadius: blob.radius * size
                    )
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Une carte de verre : matériau, voile, bordure claire, reflet en haut, ombre douce.
@MainActor
struct GlassCard: ViewModifier {
    @Environment(\.glassTheme) private var theme
    let cornerRadius: CGFloat
    /// Listes denses : voile plus opaque, pour la lisibilité.
    let dense: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = dense ? min(1, theme.cardTintOpacity + 0.25) : theme.cardTintOpacity
        content
            .background {
                ZStack {
                    if theme.usesMaterial { shape.fill(.ultraThinMaterial) }
                    shape.fill(theme.cardTint.opacity(tint))
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(theme.borderOpacity), lineWidth: 1)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(theme.highlightOpacity), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(theme.shadowOpacity), radius: theme.shadowRadius, y: theme.shadowRadius / 2)
    }
}

@MainActor
extension View {
    func glassCard(cornerRadius: CGFloat = 16, dense: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, dense: dense))
    }
}

/// Bouton principal en dégradé de la couleur d'accent avec halo, ou bouton secondaire en verre.
/// Sans `@MainActor` : `makeBody` doit satisfaire l'exigence non isolée de `ButtonStyle` (SDK macOS 14). Le corps
/// (`GlassButtonBody`) ne fait que stocker des valeurs : son initialiseur n'a pas besoin du fil principal.
public struct GlassButtonStyle: ButtonStyle {
    let prominent: Bool
    let color: Color

    public init(prominent: Bool, color: Color = .accentColor) {
        self.prominent = prominent
        self.color = color
    }

    public func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, color: color)
    }
}

/// Dimensions d'un bouton de verre selon la taille demandée (`controlSize`).
struct GlassButtonMetrics: Equatable {
    let horizontal: CGFloat
    let vertical: CGFloat
    let font: Font

    init(_ size: ControlSize) {
        switch size {
        case .mini, .small: (horizontal, vertical, font) = (10, 3, .caption.weight(.semibold))
        case .large, .extraLarge: (horizontal, vertical, font) = (20, 9, .body.weight(.semibold))
        default: (horizontal, vertical, font) = (14, 6, .callout.weight(.semibold))
        }
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let color: Color
    @Environment(\.glassTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let metrics = GlassButtonMetrics(controlSize)
        configuration.label
            .font(metrics.font)
            .lineLimit(1)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                if prominent {
                    ZStack {
                        shape.fill(Color.white)
                        shape.fill(LinearGradient(colors: [color.opacity(0.72), color], startPoint: .top, endPoint: .bottom))
                    }
                    .shadow(color: color.opacity(theme.buttonGlow > 0 ? 0.45 : 0), radius: theme.buttonGlow, y: 4)
                } else {
                    ZStack {
                        if theme.usesMaterial { shape.fill(.ultraThinMaterial) }
                        shape.fill(theme.cardTint.opacity(theme.cardTintOpacity))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(prominent ? 0.4 : theme.highlightOpacity), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
            }
            .overlay { if !prominent { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(shape)
    }
}

/// Barre de progression en dégradé, avec un halo de la couleur d'accent.
@MainActor
struct GlowProgressBar: View {
    let value: Double
    var height: CGFloat = 7
    @Environment(\.glassTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.62), Color.accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geometry.size.width * fraction))
                    .shadow(color: Color.accentColor.opacity(theme.progressGlow > 0 ? 0.6 : 0), radius: theme.progressGlow)
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityValue(Text("\(Int((min(1, max(0, value)) * 100).rounded())) %"))
    }
}
