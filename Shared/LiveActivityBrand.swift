import SwiftUI

/// Splash-screen plum palette for Live Activity surfaces (widget extension safe).
enum LiveActivityBrand {
    /// Launch screen background `#38244A`
    static let plumBackground = Color(red: 0.220, green: 0.141, blue: 0.290)
    /// Launch screen wordmark `#F2C9E3`
    static let plumAccent = Color(red: 0.949, green: 0.788, blue: 0.890)
    static let plumAccentMuted = Color(red: 0.949, green: 0.788, blue: 0.890).opacity(0.72)
}
