// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "TranslationKit",
    defaultLocalization: "en",
    // 27: ScreenCaptureKit audio capture only opened up on visionOS and iOS in 27.
    platforms: [.macOS("27.0"), .iOS("27.0"), .visionOS("27.0")],
    products: [
        .library(name: "TranslationCore", targets: ["TranslationCore"]),
        .library(name: "TranslationProviders", targets: ["TranslationProviders"]),
        .library(name: "ImagePipeline", targets: ["ImagePipeline"]),
        .library(name: "LiveCaptions", targets: ["LiveCaptions"]),
    ],
    targets: [
        // Domain layer: request/result types, prompt rules, coordination. No UI, no vendor SDKs.
        .target(name: "TranslationCore", swiftSettings: swiftSettings),
        // Model adapters: Apple on-device model, Anthropic, OpenAI-compatible endpoints.
        .target(name: "TranslationProviders", dependencies: ["TranslationCore"], swiftSettings: swiftSettings),
        // Image import and on-device OCR (Vision). Independent from providers.
        .target(name: "ImagePipeline", swiftSettings: swiftSettings),
        // Live captions for audio playing in another app: capture, streaming speech recognition,
        // caption timeline, and fast caption translation. No UI.
        .target(name: "LiveCaptions", dependencies: ["TranslationCore"], swiftSettings: swiftSettings),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"], swiftSettings: swiftSettings),
        .testTarget(name: "TranslationProvidersTests", dependencies: ["TranslationProviders"], swiftSettings: swiftSettings),
        .testTarget(name: "ImagePipelineTests", dependencies: ["ImagePipeline"], swiftSettings: swiftSettings),
        .testTarget(name: "LiveCaptionsTests", dependencies: ["LiveCaptions", "TranslationCore"], swiftSettings: swiftSettings),
    ]
)
