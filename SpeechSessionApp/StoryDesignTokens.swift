import SwiftUI
import UIKit

/// Edit these values to theme the Story Lab interface. All dimensions are in points.
/// Font names are PostScript names. Both families are registered in the app bundle.
enum StoryDesignTokens {
    static let headingFamily = "EBGaramond-Regular"
    static let bodyFamily = "Inter-Regular"

    // CollectiveCare Copper, Papaya and Mocha. Small text uses deeper copper in light mode.
    static let copper = adaptive(0xDB504A, 0xFF9F96)
    static let action = adaptive(0xA63330, 0xFFAFA5, highLight: 0x80221F, highDark: 0xFFD4CB)
    static let onAction = adaptive(0xFFFFFF, 0x302325)
    static let ink = adaptive(0x483D3F, 0xFFF1DC, highLight: 0x211B1D, highDark: 0xFFFFFF)
    static let canvas = adaptive(0xFFFCF7, 0x201C1D)
    static let surface = adaptive(0xFFFFFF, 0x302A2B)
    static let softSurface = adaptive(0xFFEECF, 0x413537)
    static let onSoftSurface = adaptive(0x483D3F, 0xFFEECF)

    static let controlHeight: CGFloat = 48
    static let iconSize: CGFloat = 44
    static let tileRadius: CGFloat = 12
    static func readingLineSpacing(for fontSize: CGFloat) -> CGFloat { fontSize * 0.28 }
    static let bodyBaseSize = baseSize(.body)

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(bodyFamily, size: baseSize(uiStyle(style)), relativeTo: style).weight(weight)
    }

    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        case .callout: return .callout
        default: return .body
        }
    }

    private static func baseSize(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }

    // Both UI frameworks use the same face and variable-font weight (700 = bold).
    private static func headingFace(size: CGFloat) -> UIFont {
        guard let face = UIFont(name: headingFamily, size: size) else {
            return .boldSystemFont(ofSize: size)
        }
        let descriptor = face.fontDescriptor.addingAttributes([
            .init(rawValue: kCTFontVariationAttribute as String): [0x77676874: 700] // wght
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func heading(_ style: Font.TextStyle) -> Font {
        .custom(headingFamily, size: baseSize(uiStyle(style)), relativeTo: style).bold()
    }

    static let sectionHeading = heading(.title2)
    static let section = heading(.headline)
    static let title = heading(.title2)
    static let body = font(.body)
    static let label = font(.headline, weight: .semibold)
    static let caption = font(.subheadline)

    // The attributed answer and its inline links receive an already Dynamic Type-scaled size.
    static func readingFont(size: CGFloat) -> UIFont {
        UIFont(name: bodyFamily, size: size) ?? .systemFont(ofSize: size)
    }

    @MainActor static func configureNavigationTypography() {
        let size = UIFont.preferredFont(forTextStyle: .largeTitle).pointSize
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: headingFace(size: size)]
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32, highLight: UInt32? = nil, highDark: UInt32? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let rgb = traits.userInterfaceStyle == .dark ? (high ? highDark ?? dark : dark) : (high ? highLight ?? light : light)
            return UIColor(red: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}
