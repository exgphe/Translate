import XCTest

/// Walks the main iOS/iPadOS flows and saves screenshots to TRANSLATE_SCREENSHOT_DIR when set.
final class TranslateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var screenshotDir: URL? {
        ProcessInfo.processInfo.environment["TRANSLATE_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func snap(_ name: String) {
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
        let editor = app.textViews["sourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("The meeting was moved to Thursday.")
        snap("1-typed")

        // Dismiss the keyboard first so its accessory bar cannot intercept the tap.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
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
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            app.buttons["Done"].firstMatch.tap()
        }
    }

    @MainActor
    func testHistoryAndSettingsAreReachable() throws {
        let history = app.buttons["historyButton"]
        if history.waitForExistence(timeout: 5) {
            history.tap()
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
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
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Privacy"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
        snap("6-privacy")
    }
}
