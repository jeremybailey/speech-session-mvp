import SwiftUI
import UIKit

/// Semantic colors from UIKit — adapt automatically to Light/Dark mode and accessibility settings.
enum BrandPalette {
    /// Screen chrome behind plain lists and sheets (`systemGroupedBackground`).
    static var canvas: Color { Color(uiColor: .systemGroupedBackground) }

    /// Elevated rows / secondary plates (`secondarySystemGroupedBackground`).
    static var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    /// Primary actions (FAB, tint-aligned controls). Uses the app’s accent color.
    static var brand: Color { Color.accentColor }

    // MARK: System UI colors (dynamic)

    static var systemBlue: Color { Color(uiColor: .systemBlue) }
    static var systemGreen: Color { Color(uiColor: .systemGreen) }
    static var systemIndigo: Color { Color(uiColor: .systemIndigo) }
    static var systemOrange: Color { Color(uiColor: .systemOrange) }
    static var systemPink: Color { Color(uiColor: .systemPink) }
    static var systemPurple: Color { Color(uiColor: .systemPurple) }
    static var systemRed: Color { Color(uiColor: .systemRed) }
    static var systemTeal: Color { Color(uiColor: .systemTeal) }
    static var systemYellow: Color { Color(uiColor: .systemYellow) }
    static var systemCyan: Color { Color(uiColor: .systemCyan) }
    static var systemGray: Color { Color(uiColor: .systemGray) }
    static var systemMint: Color { Color(uiColor: .systemMint) }
    static var systemBrown: Color { Color(uiColor: .systemBrown) }

    /// Subtle elevation shadow that respects light/dark foreground.
    static var cardShadow: Color { Color(uiColor: .label.withAlphaComponent(0.08)) }
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
                .shadow(color: BrandPalette.cardShadow, radius: 10, y: 4)
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
                .shadow(color: Color(uiColor: .label.withAlphaComponent(0.12)), radius: 10, y: 4)
        }
    }
}

struct LiquidGlassCircleModifier: ViewModifier {
    var fallbackTint: Color = Color.accentColor

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Circle())
        } else {
            content
                .background(fallbackTint, in: Circle())
                .shadow(color: Color(uiColor: .label.withAlphaComponent(0.18)), radius: 10, y: 4)
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
    /// Default Liquid Glass rounded surface over grouped screen chrome.
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

    func liquidGlassCircle(fallbackTint: Color = Color.accentColor) -> some View {
        modifier(LiquidGlassCircleModifier(fallbackTint: fallbackTint))
    }

    func liquidGlassRectangle() -> some View {
        modifier(LiquidGlassRectangleModifier())
    }
}
