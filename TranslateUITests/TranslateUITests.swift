import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// Walks the main iOS/iPadOS flows and saves screenshots to TRANSLATE_SCREENSHOT_DIR when set.
final class TranslateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var screenshotDir: URL? {
        ProcessInfo.processInfo.environment["TRANSLATE_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Keep auto-paste off unless a test turns it on, so clipboard writes don't interfere.
        app.launchArguments += ["-clipboard.autoPaste", "NO"]
        app.launch()
    }

    private var sourceEditor: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sourceEditor").firstMatch
    }

    private func openSettings() {
        #if os(iOS)
        app.buttons["workspaceMenu"].tap()
        #endif
        app.buttons["settingsButton"].firstMatch.tap()
    }

    private func snap(_ name: String) {
        #if os(visionOS)
        // XCUIScreen returns a 1×1 placeholder on visionOS. Log a timestamp and hold the state
        // so an external `simctl io screenshot` loop can capture it.
        print("SNAP \(name) \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 3)
        #endif
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = screenshotDir {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testTranslateFlowShowsErrorWhenNoEngineIsConfigured() throws {
        let editor = sourceEditor
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("The meeting was moved to Thursday.")
        snap("1-typed")

        #if os(iOS)
        XCTAssertFalse(app.buttons["Done"].exists)
        #endif
        let translate = app.buttons["translateButton"]
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        translate.tap()
        // Without Apple Intelligence or keys the app must show a recovery banner, not hang.
        let banner = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'No translation engine' OR label CONTAINS[c] 'API key' OR label CONTAINS[c] 'Apple Intelligence'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        snap("2-error-banner")

        let openSettings = app.buttons["Open Settings…"]
        if openSettings.waitForExistence(timeout: 3) {
            openSettings.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            snap("3-settings")
            app.buttons["Engines"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Engines"].waitForExistence(timeout: 5))
            snap("4-engines")
            app.navigationBars["Engines"].buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
            app.buttons["Close"].firstMatch.tap()
        }
    }

    @MainActor
    func testHistoryAndSettingsAreReachable() throws {
        let history = app.buttons["historyButton"]
        if history.waitForExistence(timeout: 5) {
            history.tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Clear History"].exists)
            snap("5-history")
            app.navigationBars.buttons.firstMatch.tap()
        } else {
            // Regular width: the sidebar may be collapsed (iPad portrait); open it first.
            if !app.staticTexts["No History"].waitForExistence(timeout: 2) {
                let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
                if toggle.waitForExistence(timeout: 3) { toggle.tap() }
            }
            XCTAssertTrue(app.staticTexts["No History"].waitForExistence(timeout: 5))
            snap("5-history-sidebar")
        }
        openSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Privacy"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
        snap("6-privacy")
    }

    #if os(iOS)
    @MainActor
    func testNativeToolbarAndHistorySettings() throws {
        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["translateButton"].isHittable)
        XCTAssertFalse(app.buttons["Done"].exists)
        snap("native-empty")

        app.buttons["importImageMenu"].tap()
        XCTAssertTrue(app.buttons["Choose Photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Image File"].exists)
        snap("native-image-menu")
        app.tap()

        openSettings()
        XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
        app.buttons["General"].tap()
        let clear = app.buttons["Clear All History…"]
        if !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        snap("native-clear-history-confirmation")
        app.buttons["Cancel"].tap()
    }
    #endif

    #if canImport(UIKit)
    /// With auto-paste on, text copied elsewhere lands in the source without any tap
    /// (after the system's one-time paste permission, which the test accepts).
    @MainActor
    func testAutoPastePicksUpNewClipboardText() throws {
        // On 2026-10-08 this test wedged the iPhone 18 Pro simulator (even `simctl io screenshot`
        // stopped responding) once the system paste prompt was involved. Opt in explicitly.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRANSLATE_RUN_AUTOPASTE_TEST"] == "1",
            "Skipped by default: the paste-permission prompt can hang the simulator."
        )
        app.terminate()
        let sample = "Auto paste sample \(Int.random(in: 1000...9999))"
        UIPasteboard.general.string = sample
        app.launchArguments = ["-clipboard.autoPaste", "YES", "-clipboard.autoPasteTranslates", "NO"]
        app.launch()
        // A fresh launch compares against the persisted change count, so new text counts as a change;
        // copy once more after launch to make that certain.
        UIPasteboard.general.string = sample
        allowPasteIfAsked()

        let editor = sourceEditor
        expectation(for: NSPredicate(format: "value CONTAINS %@", sample), evaluatedWith: editor)
        waitForExpectations(timeout: 20)
        snap("7-auto-pasted")
    }

    private func allowPasteIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<16 {
            for button in [app.buttons["Allow Paste"], springboard.buttons["Allow Paste"]] where button.exists {
                button.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// The standard paste action fills the source, and the grouped controls stay reachable.
    /// iOS presents that action in a menu so its toolbar button can use native glass styling.
    @MainActor
    func testPasteBarAndControls() throws {
        let sample = "Break a leg tonight!"
        let paste = app.buttons.matching(NSPredicate(format: "identifier == 'pasteButton' OR label == 'Paste'")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "Paste button missing from the ornament")

        UIPasteboard.general.items = []
        Thread.sleep(forTimeInterval: 2)   // let the app's clipboard watcher notice
        snap("v-empty-clipboard")

        UIPasteboard.general.string = sample
        Thread.sleep(forTimeInterval: 2)
        snap("v0-ornament")
        paste.tap()
        #if os(iOS)
        let pasteAction = app.buttons.matching(NSPredicate(format: "label == 'Paste' AND identifier != 'pasteButton'")).firstMatch
        XCTAssertTrue(pasteAction.waitForExistence(timeout: 3))
        pasteAction.tap()
        #endif

        let editor = sourceEditor
        let filled = NSPredicate(format: "value CONTAINS %@", sample)
        expectation(for: filled, evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        snap("v1-pasted")

        // Translation either completes or shows a recovery banner; both mean the request ran.
        let settled = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'No translation engine' OR label CONTAINS[c] 'API key' OR label CONTAINS[c] 'Apple Intelligence' OR label CONTAINS[c] '祝'")).firstMatch
        _ = settled.waitForExistence(timeout: 20)
        #if os(iOS)
        XCTAssertFalse(app.buttons["translateButton"].isHittable)
        #else
        XCTAssertTrue(app.buttons["translateButton"].waitForExistence(timeout: 20))
        #endif
        snap("v2-after-translate")

        if app.buttons["Context"].firstMatch.exists {
            app.buttons["Context"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Context for this translation"].waitForExistence(timeout: 5))
            snap("v3-context")
            app.buttons["Translate with Context"].firstMatch.tap()
        }

        openSettings()
        app.buttons["General"].firstMatch.tap()
        XCTAssertTrue(app.switches["Paste automatically when the clipboard changes"].waitForExistence(timeout: 5))
        snap("v4-general")
    }
    #endif

    #if os(visionOS) || os(iOS)
    /// The Live Captions panel opens from the toolbar menu. Simulators have no ScreenCaptureKit,
    /// so Start must be disabled with an explanation instead of failing later.
    @MainActor
    func testLiveCaptionsPanelOpens() throws {
        #if os(iOS)
        let actions = app.buttons["workspaceMenu"].firstMatch
        #else
        let actions = app.buttons["Actions"].firstMatch
        #endif
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        snap("lc-menu")
        app.buttons["Live Captions"].firstMatch.tap()
        snap("lc-after-tap")

        let start = app.buttons["startCaptions"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(start.isEnabled, "Capture should be unavailable in the simulator")
        XCTAssertTrue(app.staticTexts["Capturing other apps' sound is not available on this device."].waitForExistence(timeout: 5))
        snap("lc-panel")
    }
    #endif
}
