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

    // MARK: - Tests requiring a connected Tailnet

    /// Loads the app, waits until the tailnet is connected (signaled by the
    /// "Home Page" bookmark appearing — it only renders when `state == .Running`),
    /// taps it, and confirms the home page loads in the browser view.
    ///
    /// REQUIRES a simulator that is already logged into a Tailnet. Run on the
    /// iPad sim where login persists:
    ///
    ///   xcodebuild test -project TailBrowser.xcodeproj -scheme TailBrowser \
    ///     -configuration Debug \
    ///     -destination 'platform=iOS Simulator,name=iPad (A16)' \
    ///     -derivedDataPath build/DerivedData \
    ///     -only-testing:TailBrowserUITests/TailBrowserUITests/testHomePageLoadsWhenConnected
    ///
    func testHomePageLoadsWhenConnected() throws {
        let app = XCUIApplication()
        app.launch()

        // The Home Page bookmark only appears when State == .Running, so waiting
        // for it IS waiting for the tailnet to connect. Use a generous timeout —
        // the node can take a while to come up from a cold start.
        let homePageButton = app.buttons["home-page-bookmark"]
        guard homePageButton.waitForExistence(timeout: 90) else {
            attachScreenshot(app, named: "not-connected")
            XCTFail("Tailnet did not reach Running state within 90s — the Home Page " +
                    "bookmark never appeared. Is this sim logged into a Tailnet?")
            return
        }

        // Tap it → pushes BrowserView with the home page URL.
        homePageButton.tap()

        // The browser view hosts a WKWebView. Wait for it to appear.
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 30) else {
            attachScreenshot(app, named: "no-webview")
            XCTFail("Browser view / WKWebView did not appear after tapping Home Page")
            return
        }

        // Confirm the page actually loaded (not just that the view appeared).
        // We poll several native signals: the WKWebView's identifier/label, and
        // the URL text field in the browser's nav bar (which updates to the
        // current URL when the page finishes loading).
        let pageLoaded = waitForPageLoaded(in: app, contains: "tailscale.com", timeout: 60)
        attachScreenshot(app, named: pageLoaded ? "page-loaded" : "page-load-failed")
        XCTAssertTrue(pageLoaded,
                      "Home page (https://tailscale.com) did not load within 60s. " +
                      "Check libtailscale logs: xcrun simctl spawn booted log stream " +
                      "--predicate 'subsystem == \"io.tailscale.TailBrowse\"'")
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

    /// Waits for the browser page to load by polling several native signals:
    /// the WKWebView's identifier/label, and the URL text field in the nav bar
    /// (which updates to the loaded URL via `BrowserNavigator.onChange`).
    /// Returns true if any signal contained `substring` in time.
    @discardableResult
    private func waitForPageLoaded(in app: XCUIApplication, contains substring: String,
                                   timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            // Primary: the nav-bar URL text field value.
            let urlField = app.textFields["Enter URL"]
            if let val = urlField.value as? String, val.contains(substring) { return true }
            // Secondary: the WKWebView's identifier/label sometimes carries the URL.
            let webView = app.webViews.firstMatch
            if webView.exists {
                if webView.identifier.contains(substring) || webView.label.contains(substring) { return true }
            }
            return false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
