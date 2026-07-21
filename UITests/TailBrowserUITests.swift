//
//  TailBrowserUITests.swift
//  TailBrowserUITests
//
//  Trivial XCUITest smoke tests for TailBrowser.
//
//  These tests deliberately exercise only UI that does NOT require a live
//  Tailnet connection: launching the app, opening the Settings sheet, and
//  opening the Add-Bookmark editor. They exist to prove the app builds,
//  launches, and renders its core chrome — and to give us a working UI-test
//  target to grow into.
//
//  Run from the command line:
//
//    scripts/run-uitests.sh                # boots a sim, runs tests, captures logs
//    # or directly:
//    xcodebuild test -project TailBrowser.xcodeproj -scheme TailBrowser \
//      -configuration Debug \
//      -destination 'platform=iOS Simulator,name=iPhone 17' \
//      -derivedDataPath build/DerivedData
//

import XCTest

@MainActor
final class TailBrowserUITests: XCTestCase {

    override func setUpWithError() throws {
        // Stop on the first failure so we get a clean signal.
        continueAfterFailure = false
    }

    // XCTest's setUp/tearDown overrides stay nonisolated, so we can't touch
    // @MainActor XCUITest APIs there. The test methods below are @MainActor
    // (via the class), so call `attachScreenshot(_:)` from inside a test when
    // you want a snapshot.

    // MARK: - Tests

    /// The app launches and shows its main chrome (nav title + status section).
    func testAppLaunchesAndShowsStatus() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.navigationBars["TailBrowser"].waitForExistence(timeout: 20),
            "TailBrowser navigation bar should appear on launch"
        )

        XCTAssertTrue(
            app.staticTexts["Tailscale Status"].waitForExistence(timeout: 10),
            "The Tailscale Status section header should always be visible"
        )
    }

    /// Tapping the gear opens Settings; Done dismisses it.
    func testOpenAndCloseSettings() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["TailBrowser"].waitForExistence(timeout: 20))

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10),
            "Settings gear button should be reachable in the nav bar"
        )
        settingsButton.tap()

        // Settings is presented as a full-screen cover with its own nav bar.
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "Settings screen should appear after tapping the gear"
        )
        // A connection-independent control that only lives on the Settings screen.
        XCTAssertTrue(
            app.buttons["Logout"].waitForExistence(timeout: 5),
            "Logout button should be present on the Settings screen"
        )

        // Done dismisses the cover.
        let doneButton = app.buttons["settings-done-button"]
        XCTAssertTrue(doneButton.exists, "Done button should exist in Settings")
        doneButton.tap()

        // The main view's Add-Bookmark button is covered while Settings is up;
        // it becoming hittable again proves Settings actually dismissed.
        XCTAssertTrue(
            waitForHittable(app.buttons["add-bookmark-button"], timeout: 10),
            "Should return to the main view (Add Bookmark button hittable) after Done"
        )
    }

    /// Tapping + opens the bookmark editor; Cancel dismisses it.
    func testOpenAndCancelAddBookmark() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["TailBrowser"].waitForExistence(timeout: 20))

        let addButton = app.buttons["add-bookmark-button"]
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 10),
            "Add Bookmark (+) button should be reachable in the bottom toolbar"
        )
        addButton.tap()

        XCTAssertTrue(
            app.navigationBars["New Bookmark"].waitForExistence(timeout: 10),
            "Bookmark editor should appear after tapping +"
        )

        // Save starts disabled (empty name/url) — a stable, free assertion.
        let saveButton = app.buttons["bookmark-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button should exist")
        XCTAssertFalse(saveButton.isEnabled, "Save should be disabled until name+url are valid")

        let cancelButton = app.buttons["bookmark-cancel-button"]
        XCTAssertTrue(cancelButton.exists, "Cancel button should exist in the editor")
        cancelButton.tap()

        XCTAssertTrue(
            waitForHittable(app.buttons["add-bookmark-button"], timeout: 10),
            "Should return to the main view after Cancel"
        )
    }

    // MARK: - Helpers

    /// Attach a screenshot of `app` to the current test. Call from inside a
    /// test method (which is `@MainActor`), e.g. on the failure path.
    func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for `element` to become hittable (visible + tappable), which is a
    /// stronger condition than mere existence in the element tree.
    @discardableResult
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isHittable == YES")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
