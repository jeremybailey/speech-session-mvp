import SwiftUI

/// CollectiveCare brand tokens for Live Activity surfaces (widget-extension safe).
enum LiveActivityBrand {
    /// Mocha `#483d3f` — lock-screen / Dynamic Island chrome
    static let plumBackground = Color(red: 72 / 255, green: 61 / 255, blue: 63 / 255)
    /// Papaya `#ffeecf` — heart, labels, and timer on dark chrome
    static let plumAccent = Color(red: 255 / 255, green: 238 / 255, blue: 207 / 255)
    static let plumAccentMuted = Color(red: 255 / 255, green: 238 / 255, blue: 207 / 255).opacity(0.72)
    /// Copper `#db504a` — primary stop / CTA
    static let copper = Color(red: 219 / 255, green: 80 / 255, blue: 74 / 255)
}
