import SwiftUI

/// CollectiveCare visual tokens.
enum BrandPalette {
    /// Primary FAB (#38244A).
    static let brand = Color(red: 56 / 255, green: 36 / 255, blue: 74 / 255)

    /// Warm base screen tint (#FFF4E8).
    static let canvas = Color(red: 255 / 255, green: 244 / 255, blue: 232 / 255)

    /// Lighter variation of ``canvas`` for cards and other foreground surfaces.
    static let surface = Color(red: 255 / 255, green: 250 / 255, blue: 244 / 255)
}

// MARK: - Liquid Glass (iOS 26+ `glassEffect`, frosted material fallback)

/// Rounded cards / tiles (health summary sections, choice rows, sign-in panel).
struct LiquidGlassRoundedCardModifier: ViewModifier {
    var cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }
}

struct LiquidGlassCapsuleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

struct LiquidGlassCircleModifier: ViewModifier {
    var fallbackTint: Color = .blue

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Circle())
        } else {
            content
                .background(fallbackTint, in: Circle())
                .shadow(color: fallbackTint.opacity(0.35), radius: 10, y: 4)
        }
    }
}

struct LiquidGlassRectangleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

extension View {
    /// Default Liquid Glass rounded surface for floating content over ``BrandPalette.canvas``.
    func liquidGlassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidGlassRoundedCardModifier(cornerRadius: cornerRadius))
    }

    /// Alias for health / summary tiles (same as ``liquidGlassCard``).
    func summaryGlassCard(cornerRadius: CGFloat = 14) -> some View {
        liquidGlassCard(cornerRadius: cornerRadius)
    }

    func liquidGlassCapsule() -> some View {
        modifier(LiquidGlassCapsuleModifier())
    }

    func liquidGlassCircle(fallbackTint: Color = .blue) -> some View {
        modifier(LiquidGlassCircleModifier(fallbackTint: fallbackTint))
    }

    func liquidGlassRectangle() -> some View {
        modifier(LiquidGlassRectangleModifier())
    }
}
