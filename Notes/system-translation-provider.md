# iOS system translation

`TranslateProvider` is an iOS/iPadOS ExtensionKit target implementing
`TranslationUIProviderExtension` and `TranslationUIProviderSelectedTextScene`.
The app embeds it in `Translate.app/Extensions`, independently of the Safari
captions extension in `PlugIns`. The project's existing iOS 27 minimum remains.
The framework itself is available starting with iOS/iPadOS 18.4.

## Use

1. Launch Translate once after installing/updating. Configure an engine and the
   default languages in the app. Existing credentials migrate through Keychain.
2. In iOS Settings, open Apps → Default Apps → Translation and choose this app.
   The app's Settings screen also explains this and opens its public system
   settings page. There is no API to select a default app on the user's behalf.
3. Select text in another app and choose Translate in the system selection menu.
4. The system sheet immediately shows the original text and starts translating
   with the configured engine and languages. Changing a language or engine starts
   a new request. The sheet streams the result and offers Stop, Retry, Share, and
   (only when the host allows it) Replace. The system close button dismisses
   without editing. Long source text can be expanded with Show More.

Opening the system translation sheet starts a request with the app's configured
engine, including a cloud engine when selected, and respects the app's
on-device-only policy. When no engine is configured, the sheet uses the on-device
engine; it never silently selects a cloud service. Its language and
engine choices apply to the current sheet only. Selection, language, engine,
and privacy changes invalidate previous output; stopped, failed, or partial
output cannot be returned as replacement text. Dismissal cancels ongoing work.
The extension never opens the history store or reads the clipboard.

## Configuration and signing

- The iOS app uses `Config/Translate-iOS.entitlements`, including
  `com.apple.developer.translation-app = true`. macOS and visionOS retain their
  existing entitlement file and do not build/embed the new extension.
- The provider's Info.plist declares the ExtensionKit point
  `com.apple.public.translation-ui-provider` under `EXAppExtensionAttributes`.
- The Boolean Info.plist key
  `com.apple.developer.translation-ui-provider.network-access = true` is declared
  on both the app and provider, since the existing cloud engines need networking.
  This is an Info.plist declaration, not a signing entitlement.
- Non-secret translation preferences are published to the
  `group.$(DEVELOPMENT_TEAM).wang.xiaolin.Translate` App Group on iOS/iPadOS
  and visionOS. The identifier follows the selected signing team so another
  team does not attempt to register the previous team's group. macOS retains
  `$(DEVELOPMENT_TEAM).wang.xiaolin.Translate`. History, clipboard preferences, and
  selected input text are not published. App preferences remain in their original
  UserDefaults domain; updates preserve existing settings.
- Only the app and provider share
  `$(AppIdentifierPrefix)wang.xiaolin.Translate.translation-service` in Keychain.
  The app retains its original Keychain group to migrate existing credentials.
  A successful shared write removes the superseded original item; deletion
  removes both groups so a removed key cannot reappear. The Safari captions
  extension has no entitlement for either credential group.

For physical-device installation or distribution, the signing profiles for the
app and new extension must support their App Group and Keychain groups, and the
app profile must include the Default Translation App capability. Xcode automatic
signing is configured with the selected team. Keep Translate, TranslateCaptions,
and TranslateProvider on the same team in both Debug and Release. When switching
teams, Xcode registers a new App Group; launch the main app once to publish
translation settings to the new shared container. Keychain access also follows
the signing team, so credentials saved by the previous team may need to be
entered again. Mobile bundle identifiers derive from the project setting
`TRANSLATE_BUNDLE_IDENTIFIER = wang.xiaolin.Translate.$(DEVELOPMENT_TEAM)`,
with `.Captions` and `.Provider` suffixes for the extensions. macOS retains its
existing base bundle identifier. A mobile build for another team installs as a
separate app with its own preferences/history; configure it and enable its Safari
extension again. This does not transfer the existing App Store app to another
team; preserving a published app's identity requires an App Store Connect transfer
and separately handling App Group ownership. An unsigned SDK build checks
compilation and packaging, not physical-device provisioning or default-app
eligibility. Confirm the capability/profile in Signing & Capabilities before
shipping.

The installed iOS 27 SDK exposes `context.finish(translation:)`. Apple's current
article sample uses `finish(replacingWithTranslation:)`; the implementation uses
the actual installed SDK signature.

## Validation

On 2026-11-06, nine simulator tests passed for shared settings and selection
translation, including automatic start, request deduplication, stop, language
changes, empty input, stale responses, and cloud-policy enforcement. The iOS
workspace now uses a scrolling layout and native bottom toolbar. Three iPhone
simulator UI flows passed: keyboard Translate and error/settings recovery,
history/settings navigation, and bottom image controls plus the history-clear
confirmation (cancelled without deleting history). The native toolbar flow was
rerun after the final styling change. iOS simulator, unsigned iOS device SDK, and
macOS builds passed. Xcode previews verified the workspace in light/dark appearance and
larger Dynamic Type, plus a temporary app-hosted copy of the extension's content
with fixture translations (Xcode does not support JIT previews for this extension
type). The actual host sheet still needs physical-device acceptance testing.

On 2026-10-24, an automatically signed iOS device SDK build passed with team
`C2RH9KA3U2` and the team-derived bundle identifiers. The app, Safari extension,
and translation provider signatures and embedded provisioning profiles all
contain `group.C2RH9KA3U2.wang.xiaolin.Translate`; the app signature and profile
also contain `com.apple.developer.translation-app = true`. Debug and Release
resolve to the same mobile identifiers. Device installation/runtime behavior
after switching teams still needs acceptance testing.

On 2026-10-11, unsigned builds passed for iOS device, iOS simulator, macOS, and
visionOS. Seven hosted iOS simulator tests passed for configuration sharing,
stream completion, selection/request races, language/engine/privacy changes,
cancel/error handling, cloud policy enforcement, and Keychain migration/removal.
The built provider has the expected extension point and matching shared Keychain
group. The main simulator binary has the default translation entitlement.
Manual simulator checks also confirmed that Settings → Apps → Default Apps →
Translation lists this app with its icon, and that Safari's selection menu opens
the provider. A loopback-only fixture streamed a Chinese result into the actual
system sheet; a read-only selection correctly omitted Replace. The simulator
automation tool then stopped accepting coordinate input (`noWindowsAvailable`),
so end-to-end editable selection/Replace remains a physical-device acceptance
check. No external translation API was called during these manual checks.

Physical-device acceptance should cover read-only text (no Replace action), an
editable selection (Replace changes just the selection), changing languages
mid-stream, dismissal/cancellation, cloud configuration, and on-device-only mode.
Apple Intelligence inference needs a supported device and ready system model;
the simulator lifecycle tests use controlled providers instead.

## Apple references

- [TranslationUIProvider](https://developer.apple.com/documentation/translationuiprovider)
- [Preparing your app to be the default translation app](https://developer.apple.com/documentation/translationuiprovider/preparing-your-app-to-be-the-default-translation-app)
- [Translation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.translation-app)
