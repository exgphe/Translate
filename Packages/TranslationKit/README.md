# Translate

A native Apple-platform translation client that uses generative models you choose: Apple's on-device model, your own cloud API key, and (later) downloaded local models. The goal is a better system translate app: faithful first, context-aware, with text and image input, and clear about where your text goes.

Status: **v0.1 in progress, macOS first.** iOS, iPadOS and visionOS targets stay in the project and compile, but the UI is only tuned for the Mac so far. Planning documents live in `Notes/`.

## What works today (macOS)

- Type, paste, or drop text; source language detected on device; target language picker that remembers your choice.
- Engines: Apple Intelligence (on device), Anthropic (your key, direct to `api.anthropic.com`), any OpenAI-compatible endpoint (OpenAI, OpenRouter, DeepSeek, Ollama, LM Studio, …).
- Streaming output, Stop, Retry, Copy. A superseded request can never overwrite a newer result.
- Images: drop, import, or paste an image; Vision recognizes text on device; the recognized text is editable; only text is sent to the engine.
- Context popover (audience, tone, terminology) and Explain popover (idioms, ambiguity, alternatives).
- Local history (SwiftData) that can be switched off; API keys in the Keychain.
- Privacy toggle "Only translate on this device" that refuses cloud engines before any request. The app never falls back from on-device to cloud by itself.

Keyboard: ⌘↩ translate · ⌘. stop · ⌘R retry · ⇧⌘V paste and translate · ⇧⌘C copy translation · ⇧⌘I import image · ⇧⌘K context · ⇧⌘E explain · ⌘K clear.

## Layout

```
Translate.xcodeproj            Multi-platform app (macOS / iOS / iPadOS / visionOS, min 27.0)
Translate/                     App target: SwiftUI views, workspace state, persistence, platform glue
  App/                         AppModel (composition root), menu commands
  Workspace/                   TranslationWorkspace (screen state), EngineRegistry (builds providers)
  Persistence/                 AppSettings (UserDefaults), KeychainStore, HistoryEntry (SwiftData)
  Views/                       ContentView, TranslationView, HistorySidebar, SettingsView
  Platform/                    Pasteboard and drop helpers per OS
Packages/TranslationKit/       Local Swift package, no UI
  TranslationCore/             Request / event / result types, prompt rules, coordinator, SSE parser
  TranslationProviders/        AppleSystemModelProvider, AnthropicProvider, OpenAICompatibleProvider
  ImagePipeline/               Image decoding and Vision OCR with reading-order assembly
Notes/                         Product plan and story map
```

Dependency direction is strictly downward: views → workspace → coordinator → core protocols ← providers. The UI never touches HTTP, model sessions, or Vision.

Key types in `TranslationCore`:

- `TranslationRequest` is an immutable snapshot (id, text, languages, mode, context, glossary, network policy, prompt version).
- `TranslationEvent` distinguishes `textDelta` from `textSnapshot`; adapters normalize every vendor's streaming style so text is never duplicated.
- `TranslationProvider` is the only interface an engine must implement: `availability()` and `translate(_:) -> AsyncThrowingStream`.
- `TranslationCoordinator` runs local checks, language detection, policy enforcement, and folds the stream into snapshots.
- `TranslationPrompt.version` must change whenever prompt wording changes.

## Building

Requires Xcode 27. Open `Translate.xcodeproj` and run the `Translate` scheme on My Mac.

Package tests (core, providers, OCR) run without Xcode UI:

```
cd Packages/TranslationKit && swift test
```

The on-device model tests run real inference when Apple Intelligence is enabled and are skipped otherwise.

## Privacy rules (fixed from v0.1)

1. On-device failure never silently switches to a cloud engine.
2. OCR failure never uploads the original image.
3. History is never used as context for a new request.
4. Keys are stored only in the Keychain and never logged or exported.

## Roadmap

See `Notes/native-ai-translate-project-plan.md`. Next: daily use for a week, then menu bar entry, iOS/iPadOS layouts, the default-translation-app extension probe, and a verified downloadable model.

## License

MIT for the code. Model weights and third-party services are governed by their own licenses and terms; usage of cloud services is billed to your own account.
