import Foundation

#if os(iOS)
import UIKit
#endif

public enum DeviceCapabilityTier: Sendable {
    case legacy
    case standard
    case advanced
}

/// Device capability checks for local WhisperKit model sizes.
///
/// **Legacy** tier always allows Tiny; Base (and experimental Tiny+Base on very old hardware) requires the Settings toggle. Unknown devices are treated as `standard`, not `advanced`.
public struct DeviceCapabilityProfile: Sendable {
    public static let tinyWhisperKitModel = "openai_whisper-tiny.en"
    public static let baseWhisperKitModel = "openai_whisper-base.en"
    public static let smallWhisperKitModel = "openai_whisper-small.en"
    public static let mediumWhisperKitModel = "openai_whisper-medium.en"

    public let modelIdentifier: String
    public let tier: DeviceCapabilityTier

    public static var current: DeviceCapabilityProfile {
        let identifier = currentModelIdentifier()
        return DeviceCapabilityProfile(
            modelIdentifier: identifier,
            tier: tier(for: identifier)
        )
    }

    /// True when this tier runs WhisperKit without the legacy “extra models” toggle (Tiny is always allowed on legacy; see `allowedWhisperKitModels`).
    public var supportsWhisperKit: Bool {
        tier != .legacy
    }

    public var whisperKitUnavailableReason: String? {
        nil
    }

    public var allowedWhisperKitModelNames: [String] {
        switch tier {
        case .legacy:
            return [Self.tinyWhisperKitModel]
        case .standard:
            return [
                Self.tinyWhisperKitModel,
                Self.baseWhisperKitModel,
            ]
        case .advanced:
            return [
                Self.tinyWhisperKitModel,
                Self.baseWhisperKitModel,
                Self.smallWhisperKitModel,
                Self.mediumWhisperKitModel,
            ]
        }
    }

    public func supportsWhisperKitModel(_ modelName: String) -> Bool {
        allowedWhisperKitModelNames.contains(modelName)
    }

    /// Tiny + Base on **legacy** tier when the user enables experimental (Tiny alone is always allowed on legacy).
    public static let experimentalLegacyWhisperKitModels: [String] = [
        Self.tinyWhisperKitModel,
        Self.baseWhisperKitModel,
    ]

    /// WhisperKit (at least Tiny) is always permitted on supported platforms.
    public func permitsWhisperKit(experimentalUnlocked: Bool) -> Bool {
        _ = experimentalUnlocked
        return true
    }

    /// Model IDs allowed for download and transcription, accounting for optional experimental unlock on legacy-tier devices (adds Base).
    public func allowedWhisperKitModels(experimentalUnlocked: Bool) -> [String] {
        if tier == .legacy {
            return experimentalUnlocked
                ? Self.experimentalLegacyWhisperKitModels
                : [Self.tinyWhisperKitModel]
        }
        return allowedWhisperKitModelNames
    }

    public func permitsWhisperKitModel(_ modelName: String, experimentalUnlocked: Bool) -> Bool {
        allowedWhisperKitModels(experimentalUnlocked: experimentalUnlocked).contains(modelName)
    }

    /// When WhisperKit cannot be used at all for this profile; `nil` if permitted (including via experimental unlock).
    public func whisperKitHardBlockReason(experimentalUnlocked: Bool) -> String? {
        if permitsWhisperKit(experimentalUnlocked: experimentalUnlocked) { return nil }
        return whisperKitUnavailableReason
    }

    /// When OpenAI Whisper is unavailable, prefer Apple on-device speech. Cloud Whisper is available when the user is signed in
    /// with a configured proxy (`kindeSignedInWithProxy`) and/or, in **Debug** builds only, a non-empty BYOK string.
    public func fallbackTranscriptionBackend(openAIAPIKey: String, kindeSignedInWithProxy: Bool) -> TranscriptionBackend {
        #if DEBUG
        let byok = !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #else
        let byok = false
        #endif
        if kindeSignedInWithProxy || byok { return .openAIWhisper }
        return .onDeviceApple
    }

    private static func tier(for identifier: String) -> DeviceCapabilityTier {
        if identifier == "i386" || identifier == "x86_64" || identifier == "arm64" {
            return .standard
        }

        if let iPhoneMajor = majorVersion(from: identifier, prefix: "iPhone") {
            if iPhoneMajor <= 11 { return .legacy }      // iPhone XR / XS and older.
            if iPhoneMajor <= 14 { return .standard }    // Conservative: tiny/base only.
            return .advanced
        }

        if let iPadMajor = majorVersion(from: identifier, prefix: "iPad") {
            if iPadMajor <= 8 { return .legacy }
            if iPadMajor <= 13 { return .standard }
            return .advanced
        }

        #if os(iOS)
        let memory = ProcessInfo.processInfo.physicalMemory
        if memory < 4_000_000_000 { return .legacy }
        if memory < 6_000_000_000 { return .standard }
        return .advanced
        #else
        return .standard
        #endif
    }

    private static func majorVersion(from identifier: String, prefix: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let version = identifier.dropFirst(prefix.count)
        let major = version.split(separator: ",").first
        return major.flatMap { Int($0) }
    }

    private static func currentModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModel
        }
        #endif

        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
