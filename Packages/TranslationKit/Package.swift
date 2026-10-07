// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "TranslationKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "TranslationCore", targets: ["TranslationCore"]),
        .library(name: "TranslationProviders", targets: ["TranslationProviders"]),
        .library(name: "ImagePipeline", targets: ["ImagePipeline"]),
    ],
    targets: [
        // Domain layer: request/result types, prompt rules, coordination. No UI, no vendor SDKs.
        .target(name: "TranslationCore", swiftSettings: swiftSettings),
        // Model adapters: Apple on-device model, Anthropic, OpenAI-compatible endpoints.
        .target(name: "TranslationProviders", dependencies: ["TranslationCore"], swiftSettings: swiftSettings),
        // Image import and on-device OCR (Vision). Independent from providers.
        .target(name: "ImagePipeline", swiftSettings: swiftSettings),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"], swiftSettings: swiftSettings),
        .testTarget(name: "TranslationProvidersTests", dependencies: ["TranslationProviders"], swiftSettings: swiftSettings),
        .testTarget(name: "ImagePipelineTests", dependencies: ["ImagePipeline"], swiftSettings: swiftSettings),
    ]
)
