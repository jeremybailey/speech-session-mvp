import Foundation

#if os(iOS)
import UIKit
#endif

public enum DeviceCapabilityTier: Sendable {
    case legacy
    case standard
    case advanced
}

/// Conservative device capability checks for local model features.
///
/// Unknown devices are treated as `standard`, not `advanced`, so new model sizes
/// are only enabled where we are reasonably confident they can run.
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

    public var supportsWhisperKit: Bool {
        tier != .legacy
    }

    public var whisperKitUnavailableReason: String? {
        guard !supportsWhisperKit else { return nil }
        return "On-device Whisper models are not available on this iPhone. Use Apple Speech or OpenAI Whisper."
    }

    public var allowedWhisperKitModelNames: [String] {
        switch tier {
        case .legacy:
            return []
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

    public func fallbackTranscriptionBackend(openAIAPIKey: String) -> TranscriptionBackend {
        openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .onDeviceApple : .openAIWhisper
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
