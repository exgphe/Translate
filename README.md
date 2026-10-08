# Translate

A native translation app for Apple platforms that uses generative models you choose: Apple's on-device model, your own cloud API key, or a local inference server. The aim is a better system translate app — faithful first, context-aware, with text and image input, and always clear about where your text goes.

Free and open source (MIT). No account, no proxy, no shared key: cloud usage is billed to your own provider account.

**Status:** v0.1 on macOS, with iPhone, iPad, and Apple Vision Pro layouts in place.

## Features

- **Text in, translation out.** Type, paste, or drop text. Source language is detected on device; the target language picker remembers your choice.
- **Bring your own model.**
  - Apple Intelligence — on device, nothing leaves the Mac.
  - Anthropic — direct to `api.anthropic.com` with your key (streaming, server-side refusal fallback).
  - Any OpenAI-compatible Chat Completions endpoint — OpenAI, OpenRouter, DeepSeek, Gemini's compatibility API, or a local server such as Ollama or LM Studio.
- **Streaming** output with Stop, Retry, and Copy. A superseded request can never overwrite a newer result.
- **Images.** Drop, import, or paste a screenshot; Vision recognizes the text on device; you can edit it before translating. Only the text is sent to the engine.
- **Context and Explain.** Tell the engine about audience, tone, or terminology; ask it to explain idioms, ambiguity, and alternatives.
- **Local history** (SwiftData) that can be switched off. API keys live in the Keychain.
- **"Only translate on this device"** refuses cloud engines before any request is made.
- **One action bar everywhere.** Engine | Paste, Copy | Context, Explain | Translate. Paste is the system Paste button: it pastes and translates in one step, never shows the paste permission prompt, and turns gray when the clipboard is empty.
- **Adaptive layout.** Mac and iPad: history sidebar, source and translation side by side, action bar along the bottom. iPhone and narrow iPad windows: source above translation, the action bar on two rows with Translate in thumb reach, history pushed from the toolbar, settings and context as sheets, a keyboard bar with Translate / Done, and photo picking from the library.
- **Apple Vision Pro.** The action bar floats in a glass ornament below the window, away from the edge, so every control is easy to target by eye.
- **Optional auto-paste.** When turned on, new clipboard text or images are pasted (and optionally translated) while the app is open. Off by default. Text copied from this app is ignored.

Keyboard: `⌘↩` translate · `⌘.` stop · `⌘R` retry · `⇧⌘V` paste and translate · `⇧⌘C` copy translation · `⇧⌘I` import image · `⇧⌘K` context · `⇧⌘E` explain · `⌘K` clear.

## Privacy rules

These are fixed design rules, not settings:

1. The app never falls back from on-device to cloud by itself.
2. An OCR failure never uploads the original image.
3. History is never used as context for a new request.
4. Keys are stored only in the Keychain and never logged or exported.
5. Every result shows which model produced it and whether it ran on device, on a local server, or in the cloud.

## Requirements

- macOS 27 (iOS / iPadOS / visionOS 27 for the other targets)
- Xcode 27
- Apple Intelligence enabled for the on-device engine, or an API key for a cloud engine

## Building

```bash
git clone <this repository>
open Translate.xcodeproj      # run the "Translate" scheme on My Mac
```

Package tests (core, providers, OCR) run without the Xcode UI:

```bash
cd Packages/TranslationKit && swift test
```

The on-device model tests run real inference when Apple Intelligence is available and are skipped otherwise. An optional live test against an OpenAI-compatible endpoint runs only when `TRANSLATE_OPENAI_BASE`, `TRANSLATE_OPENAI_MODEL`, and `TRANSLATE_OPENAI_KEY` are set.

UI tests walk the iPhone and iPad flows (type, translate, recover from a missing engine, open history and settings) and attach screenshots to the result bundle:

```bash
xcodebuild -scheme Translate -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:TranslateUITests -parallel-testing-enabled NO test
```

## Project layout

```
Translate.xcodeproj            Multi-platform app (macOS / iOS / iPadOS / visionOS)
Translate/                     App target: SwiftUI views, workspace state, persistence, platform glue
  App/                         AppModel (composition root), menu commands
  Workspace/                   TranslationWorkspace (screen state), EngineRegistry (builds providers)
  Persistence/                 AppSettings (UserDefaults), KeychainStore, HistoryEntry (SwiftData)
  Views/                       ContentView, TranslationView, HistorySidebar, SettingsView
  Platform/                    Pasteboard and drag-and-drop helpers per OS
  AppIcon.icon                 Icon Composer package (all-vector Liquid Glass icon)
Packages/TranslationKit/       Local Swift package, no UI
  TranslationCore/             Request / event / result types, prompt rules, coordinator, SSE parsing
  TranslationProviders/        AppleSystemModelProvider, AnthropicProvider, OpenAICompatibleProvider
  ImagePipeline/               Image decoding and Vision OCR with reading-order assembly
Design/AppIcon/                Scripts that generate the icon's SVG layers
Notes/                         Product plan and story map
```

Dependencies point strictly downward: views → workspace → coordinator → core protocols ← providers. The UI never touches HTTP, model sessions, or Vision.

Key types in `TranslationCore`:

- `TranslationRequest` — an immutable snapshot: id, text, languages, mode, context, glossary, network policy, prompt version.
- `TranslationEvent` — distinguishes `textDelta` from `textSnapshot`, so adapters can normalize any vendor's streaming style without duplicating text.
- `TranslationProvider` — the only interface an engine implements: `availability()` and `translate(_:) -> AsyncThrowingStream`.
- `TranslationCoordinator` — local checks, language detection, policy enforcement, stream folding, empty-result detection.
- `TranslationPrompt.version` — bump it whenever prompt wording changes.

## Adding an engine

Implement `TranslationProvider` in `TranslationProviders`, map vendor errors onto `TranslationError`, report an honest `ProcessingLocation`, and register it in `EngineRegistry`. Streaming adapters should read the body with `HTTPSupport.forEachEvent`, which preserves the blank lines that delimit server-sent events.

## Roadmap

See `Notes/native-ai-translate-project-plan.md`. Next up: a week of daily use, the macOS menu bar entry, the share and default-translation-app extensions on iOS, camera capture, Chinese UI strings, and a verified downloadable model.

## License

MIT — see [LICENSE](LICENSE). Model weights and third-party services are governed by their own licenses and terms.
