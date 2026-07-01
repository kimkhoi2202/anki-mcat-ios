import XCTest

/// Native-layer UI smoke tests driving the real app through XCUITest.
///
/// Coverage: launching to the deck list, opening Settings and the card browser
/// from the toolbar, the New Deck dialog, the configurable-gestures screen, the
/// daily review-reminder setting, and a full study round-trip (reveal + grade).
///
/// These use only visible text + accessibility labels (no app-source changes),
/// plus the app's existing DEBUG launch hooks (`-startIn…` / `-demo…`) to reach
/// specific screens deterministically. First-launch onboarding is skipped by
/// presetting its `@AppStorage` flag (`IntroductionSlidesShown`) through the
/// UserDefaults argument domain, so every test starts from a known state.
///
/// This target lives on the `feat/ui-tests` branch; `main` stays the clean base
/// app (the target is purely additive and touches no app source).
final class AnkiSpeedrunUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches a fresh app instance with onboarding skipped, plus any extra
    /// launch arguments (the app's DEBUG automation hooks).
    @discardableResult
    private func launchApp(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Skip the first-launch onboarding so tests start on the deck list. The
        // UserDefaults argument domain sets the @AppStorage("IntroductionSlidesShown").
        app.launchArguments += ["-IntroductionSlidesShown", "YES"]
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    /// Launches and waits for the deck list (booting + opening the collection
    /// takes a moment on a cold start).
    @discardableResult
    private func launchToDeckList(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Decks"].firstMatch.waitForExistence(timeout: 30),
                      "The deck list should appear on launch", file: file, line: line)
        return app
    }

    /// The "New Deck" action is a `Label`-based button (no explicit
    /// accessibilityLabel), so it may surface as a button matched by label or as
    /// the tappable "New Deck" static text — resolve whichever is present.
    private func newDeckAction(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Deck")).firstMatch
        if button.waitForExistence(timeout: 5) { return button }
        return app.staticTexts["New Deck"].firstMatch
    }

    // MARK: - Launch / deck list

    /// The app boots to the deck list without crashing, showing the seeded
    /// Default deck and the deck-creation action.
    func testLaunchesToDeckList() {
        let app = launchToDeckList()
        XCTAssertTrue(app.staticTexts["Default"].waitForExistence(timeout: 10),
                      "The seeded Default deck should be listed")
        XCTAssertTrue(newDeckAction(in: app).exists,
                      "The New Deck action should be present")
    }

    // MARK: - Toolbar navigation

    /// The gear toolbar button opens Settings.
    func testOpenSettingsFromToolbar() {
        let app = launchToDeckList()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "Tapping the toolbar gear should open Settings")
    }

    /// The magnifying-glass toolbar button opens the card browser.
    func testOpenCardBrowserFromToolbar() {
        let app = launchToDeckList()
        app.buttons["Browse cards"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15),
                      "Tapping Browse should open the card browser with a search field")
    }

    // MARK: - Deck creation

    /// The New Deck action presents the naming dialog.
    func testNewDeckDialogAppears() {
        let app = launchToDeckList()
        newDeckAction(in: app).tap()
        let alert = app.alerts["New Deck"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10),
                      "Tapping New Deck should present the New Deck dialog")
        if alert.buttons["Cancel"].exists { alert.buttons["Cancel"].tap() }
    }

    // MARK: - Configurable gestures (Controls)

    /// The Controls/Gestures screen renders the 3×3 tap-zone grid.
    func testGesturesScreenRendersTapZones() {
        let app = launchApp(["-startInControls"])
        XCTAssertTrue(app.navigationBars["Gestures"].waitForExistence(timeout: 30),
                      "The Controls/Gestures screen should open")
        XCTAssertTrue(app.staticTexts["Tap center"].waitForExistence(timeout: 10),
                      "The tap-zone grid rows should be listed")
    }

    // MARK: - Review reminder setting

    /// The daily review-reminder setting appears in Settings.
    func testReviewReminderSettingAppears() {
        let app = launchApp(["-demoReviewReminder"])
        let reminderSwitch = app.switches["Daily review reminder"]
        let reminderText = app.staticTexts["Daily review reminder"]
        XCTAssertTrue(reminderSwitch.waitForExistence(timeout: 30)
                      || reminderText.waitForExistence(timeout: 5),
                      "The daily review reminder setting should appear in Settings")
    }

    // MARK: - Study round-trip

    /// Studying: open the reviewer, reveal the answer, and grade the card.
    func testStudyRevealAndGrade() {
        let app = launchApp(["-startInReview"])
        let showAnswer = app.buttons["Show Answer"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 30),
                      "The reviewer should open on a card with a Show Answer button")
        showAnswer.tap()
        // "Good" may carry its next-interval in the accessibility label, so match
        // by prefix rather than an exact string.
        let good = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Good")).firstMatch
        XCTAssertTrue(good.waitForExistence(timeout: 10),
                      "Grade buttons should appear after revealing the answer")
        good.tap()
        // The Default deck has several new cards, so grading advances to the next
        // card (Show Answer reappears) or reaches the finished state — either way
        // the app stays responsive.
        let advanced = app.buttons["Show Answer"].waitForExistence(timeout: 10)
            || app.navigationBars["Decks"].waitForExistence(timeout: 5)
        XCTAssertTrue(advanced, "After grading, the reviewer should advance or finish")
        XCTAssertEqual(app.state, .runningForeground, "The app should not crash while studying")
    }
}
