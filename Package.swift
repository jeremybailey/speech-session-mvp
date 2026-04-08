// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeechSessionMVP",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SpeechSessionPersistence", targets: ["SpeechSessionPersistence"]),
        .library(name: "SpeechSessionTranscription", targets: ["SpeechSessionTranscription"]),
        .library(name: "SpeechSessionAudio", targets: ["SpeechSessionAudio"]),
        .library(name: "SpeechSessionFeatures", targets: ["SpeechSessionFeatures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .target(name: "SpeechSessionPersistence"),
        .target(
            name: "SpeechSessionTranscription",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        .target(
            name: "SpeechSessionAudio",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "SpeechSessionFeatures",
            dependencies: [
                "SpeechSessionPersistence",
                "SpeechSessionTranscription",
                "SpeechSessionAudio",
            ]
        ),
        .testTarget(
            name: "SpeechSessionPersistenceTests",
            dependencies: ["SpeechSessionPersistence"]
        ),
    ]
)
