//
//  ApertureUITests.swift
//  ApertureUITests
//
//  Trivial XCUITest smoke tests for Aperture.
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
//    xcodebuild test -project Aperture.xcodeproj -scheme Aperture \
//      -configuration Debug \
//      -destination 'platform=iOS Simulator,name=iPhone 17' \
//      -derivedDataPath build/DerivedData
//

import XCTest

@MainActor
final class ApertureUITests: XCTestCase {

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
            app.navigationBars["Aperture"].waitForExistence(timeout: 20),
            "Aperture navigation bar should appear on launch"
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

        XCTAssertTrue(app.navigationBars["Aperture"].waitForExistence(timeout: 20))

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

        XCTAssertTrue(app.navigationBars["Aperture"].waitForExistence(timeout: 20))

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

    // MARK: - Tests

    /// Editing the Home Page in Settings and then dismissing **without**
    /// pressing Return should still persist — the value must survive a fresh
    /// app launch, which re-seeds the field from UserDefaults (the on-disk
    /// source of truth).
    ///
    /// This catches the bug where the home page was only saved inside the
    /// TextField's `onSubmit` (the Return key). A user who typed a new URL and
    /// tapped Done (no Return) lost the change: `HomePage.standard.url` (the
    /// UserDefaults-backed getter) was never written, so the next launch —
    /// and any re-presentation of Settings that builds a fresh
    /// `SettingsViewModel` — showed the old value again.
    ///
    /// We verify persistence across a `terminate()` + `launch()` rather than
    /// merely re-opening Settings within the same session: a new process
    /// guarantees a brand-new `SettingsViewModel` reading from UserDefaults,
    /// with no chance of a reused in-memory instance masking the bug.
    ///
    /// Connection-independent: Settings is always reachable from the nav bar,
    /// and the Home Page section is always visible.
    ///
    /// Hermetic: it reads the original value, changes it, verifies, then
    /// restores the original. (On a pre-fix build the change never reaches
    /// UserDefaults, so nothing is left dirty either.)
    func testHomePageSettingPersistsAcrossSettingsReopen() throws {
        let app = XCUIApplication()
        // Start from a known home page so the test isn't polluted by whatever
        // a prior run left in UserDefaults. (Cleared before the relaunch below
        // so we observe what actually persisted, not a freshly-reset value.)
        app.launchArguments = ["-UITestResetHomePage"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Aperture"].waitForExistence(timeout: 20))

        // --- First visit: read the current value, then change it ---
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10),
                      "Settings gear should be reachable in the nav bar")
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings screen should appear after tapping the gear")

        let homePageField = app.textFields["home-page-field"]
        XCTAssertTrue(homePageField.waitForExistence(timeout: 10),
                      "Home Page text field should be present in Settings")
        let originalValue = (homePageField.value as? String) ?? ""

        // A value guaranteed to differ from whatever is currently set.
        let marker = String(UUID().uuidString.prefix(8))
        let newValue = "https://example.test/\(marker)"

        homePageField.clearAndType(text: newValue)
        // Sanity: the binding actually took the new value before we dismiss.
        XCTAssertEqual(homePageField.value as? String, newValue,
                       "Typing should update the Home Page field")

        // Dismiss Settings WITHOUT pressing Return — this is exactly the
        // scenario that was broken. (Pressing Return would trigger onSubmit,
        // which did save; tapping Done alone did not.)
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(waitForHittable(app.buttons["add-bookmark-button"], timeout: 10),
                      "Should return to the main view after Done")

        // --- Kill and relaunch so a fresh SettingsViewModel reads from
        // UserDefaults rather than a possibly-reused in-memory instance ---
        app.launchArguments = []   // do NOT reset — we want to see what saved
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Aperture"].waitForExistence(timeout: 20),
                      "App should relaunch")

        // --- Second visit (fresh process): the change must have persisted ---
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings screen should reappear after relaunch")

        let homePageFieldAfter = app.textFields["home-page-field"]
        XCTAssertTrue(homePageFieldAfter.waitForExistence(timeout: 10))
        let persistedValue = (homePageFieldAfter.value as? String) ?? ""

        attachScreenshot(app, named: persistedValue == newValue ? "homepage-saved" : "homepage-lost")
        XCTAssertEqual(persistedValue, newValue,
                       "Home Page should persist across a relaunch after " +
                       "dismissing Settings without pressing Return. Got " +
                       "'\(persistedValue)', expected '\(newValue)'.")

        // --- Restore the original value so the test is hermetic ---
        homePageFieldAfter.clearAndType(text: originalValue)
        app.buttons["settings-done-button"].tap()
    }

    // MARK: - Tests requiring a connected Tailnet

    /// Loads the app, waits until the tailnet is connected (signaled by the
    /// "Home Page" bookmark appearing — it only renders when `state == .Running`),
    /// taps it, and confirms the home page loads in the browser view.
    ///
    /// REQUIRES a simulator that is already logged into a Tailnet. Run on the
    /// iPad sim where login persists:
    ///
    ///   xcodebuild test -project Aperture.xcodeproj -scheme Aperture \
    ///     -configuration Debug \
    ///     -destination 'platform=iOS Simulator,name=iPad (A16)' \
    ///     -derivedDataPath build/DerivedData \
    ///     -only-testing:ApertureUITests/ApertureUITests/testHomePageLoadsWhenConnected
    ///
    /// On a simulator that is NOT logged in, this test is **skipped** (not
    /// failed) — the 3 smoke tests still run green on any sim, and `make test`
    /// stays green. To force a real failure when expected-connected, pass the
    /// launch argument `-RequireConnected` (see below).
    func testHomePageLoadsWhenConnected() throws {
        let app = XCUIApplication()
        // Opt-in flag: when set, a not-connected sim is a hard failure instead
        // of a skip. Useful for CI runs that are known to be logged in.
        let requireConnected = app.launchArguments.contains("-RequireConnected")
        app.launch()

        // The Home Page bookmark only appears when State == .Running, so waiting
        // for it IS waiting for the tailnet to connect. Use a generous timeout —
        // the node can take a while to come up from a cold start.
        let homePageButton = app.buttons["home-page-bookmark"]
        guard homePageButton.waitForExistence(timeout: 90) else {
            attachScreenshot(app, named: "not-connected")
            let msg = "Tailnet did not reach Running state within 90s — the Home " +
                      "Page bookmark never appeared. Is this sim logged into a Tailnet?"
            if requireConnected {
                XCTFail(msg)
            } else {
                // Skip, not fail: not-connected is the normal state on a fresh sim.
                throw XCTSkip(msg)
            }
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
        let pageLoaded = waitForPageLoaded(in: app, contains: "ai", timeout: 60)
        attachScreenshot(app, named: pageLoaded ? "page-loaded" : "page-load-failed")
        XCTAssertTrue(pageLoaded,
                      "Home page (http://ai/chat) did not load within 60s. " +
                      "Check libtailscale logs: xcrun simctl spawn booted log stream " +
                      "--predicate 'subsystem == \"io.tailscale.Aperture\"'")
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

// MARK: - XCUIElement helpers

private extension XCUIElement {
    /// Clears the current text (by deleting back to empty) then types `text`.
    ///
    /// Each delete and each typed character drives the SwiftUI `Binding`, so
    /// this is the right way to exercise an `.onChange`-backed field in
    /// XCUITest (and also a `.onSubmit`-only field, where only the final
    /// Return would persist — which we deliberately avoid in the home-page
    /// persistence test).
    func clearAndType(text: String) {
        tap()
        // Over-delete rather than deleting by `value.count`: the accessibility
        // `value` can disagree with the true editable text length (e.g. it may
        // report the placeholder), and pressing delete on an empty field is a
        // no-op, so a generous fixed count reliably clears the field.
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100)
        typeText(deletes)
        typeText(text)
    }
}
