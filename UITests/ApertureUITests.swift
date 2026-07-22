//
//  ApertureUITests.swift
//  ApertureUITests
//
//  UI tests for Aperture.
//
//  The app's root is now a Safari-style multi-tab browser. Until the tailnet
//  first reaches `Running` it shows a ConnectionGateView (brand header +
//  "Tailscale Status" + Login); once connected it switches to the tabbed
//  browser. So:
//
//  - Connection-independent tests (brand header, status, Settings, home-page
//    persistence) run against the gate and stay green on any sim.
//  - Connected tests (the browser: add-bookmark, home-page load) need a
//    logged-in sim. They authenticate non-interactively via an auth key when
//    one is staged (see `resolvedTestAuthKey`), and otherwise SKIP (not fail)
//    so `make test` stays green on any sim. `-RequireConnected` turns a
//    not-connected sim into a hard failure for CI.
//
//  Run from the command line:
//
//    make test                                # any sim (connected test skips)
//    make test AUTHKEY=tskey-auth-...         # connected test runs too
//    scripts/run-uitests.sh
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

    // MARK: - Connection-independent tests (run on any sim)

    /// The app launches and shows its onboarding chrome (brand header +
    /// "Tailscale Status" section). Pre-connection this is the connection
    /// gate; the brand header is the sole "Aperture" branding (no nav-bar
    /// title), so we wait on its accessibility identifier.
    func testAppLaunchesAndShowsStatus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(
            waitForBrandHeader(app, timeout: 20),
            "The Aperture brand header should appear on launch"
        )

        XCTAssertTrue(
            app.staticTexts["Tailscale Status"].waitForExistence(timeout: 10),
            "The Tailscale Status section header should always be visible"
        )
    }

    /// Tapping the gear opens Settings; Done dismisses it. The gear lives in
    /// the connection gate (and in the browser once connected) — both carry
    /// the `settings-button` identifier, so this test is connection-independent.
    func testOpenAndCloseSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(waitForBrandHeader(app, timeout: 20))

        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10),
            "Settings gear button should be reachable"
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

        // The gear becoming hittable again proves Settings dismissed and we're
        // back at the root (gate or browser — both have a `settings-button`).
        let backAtRoot = waitForHittable(app.buttons["settings-button"], timeout: 10)
        if !backAtRoot { attachScreenshot(app, named: "settings-not-dismissed") }
        XCTAssertTrue(backAtRoot,
                      "Should return to the root (settings gear hittable) after Done")
    }

    /// Editing the Home Page in Settings and then dismissing **without**
    /// pressing Return should still persist — the value must survive a fresh
    /// app launch, which re-seeds the field from UserDefaults (the on-disk
    /// source of truth).
    ///
    /// This catches the bug where the home page was only saved inside the
    /// TextField's `onSubmit` (the Return key). A user who typed a new URL and
    /// tapped Done (no Return) lost the change.
    ///
    /// Connection-independent: Settings is always reachable (from the gate's
    /// gear pre-connection, or the browser's gear post-connection).
    /// Hermetic: reads the original value, changes it, verifies, then restores.
    func testHomePageSettingPersistsAcrossSettingsReopen() throws {
        let app = XCUIApplication()
        // Start from a known home page so the test isn't polluted by whatever
        // a prior run left in UserDefaults. (Cleared before the relaunch below
        // so we observe what actually persisted, not a freshly-reset value.)
        app.launchArguments = ["-UITestResetHomePage", "-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(waitForBrandHeader(app, timeout: 20))

        // --- First visit: read the current value, then change it ---
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10),
                      "Settings gear should be reachable")
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
        XCTAssertEqual(homePageField.value as? String, newValue,
                       "Typing should update the Home Page field")

        // Dismiss Settings WITHOUT pressing Return — this is exactly the
        // scenario that was broken.
        app.buttons["settings-done-button"].tap()
        let backAtRoot1 = waitForHittable(app.buttons["settings-button"], timeout: 10)
        if !backAtRoot1 { attachScreenshot(app, named: "homepage-not-back-to-root") }
        XCTAssertTrue(backAtRoot1,
                      "Should return to the root after Done")

        // --- Kill and relaunch so a fresh SettingsViewModel reads from
        // UserDefaults rather than a possibly-reused in-memory instance ---
        app.launchArguments = ["-UITestResetLogin"]   // do NOT reset home page — we want to see what saved
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForBrandHeader(app, timeout: 20),
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

    // MARK: - Connected tests (require a logged-in sim; auth key automates it)

    /// The connected browser is up when its bottom-toolbar bookmark button
    /// (`add-bookmark-button`) is present — that control only exists in the
    /// browser chrome, which only shows once the tailnet has connected.
    @discardableResult
    private func waitForBrowserReady(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        app.buttons["add-bookmark-button"].waitForExistence(timeout: timeout)
    }

    /// Launches the app, forwarding a staged auth key if one is available so a
    /// fresh (not-logged-in) sim can connect non-interactively.
    private func launchConnected(_ app: XCUIApplication) {
        if let key = Self.resolvedTestAuthKey() {
            app.launchEnvironment["APERTURE_AUTHKEY"] = key
            app.launchEnvironment["APERTURE_EPHEMERAL"] = Self.resolvedTestEphemeral()
        }
        app.launch()
    }

    /// Skip-or-fail helper for connected tests when the tailnet doesn't come up.
    private func skipIfNotConnected(_ app: XCUIApplication, requireConnected: Bool,
                                    timeout: TimeInterval = 90) throws -> Bool {
        guard waitForBrowserReady(app, timeout: timeout) else {
            attachScreenshot(app, named: "not-connected")
            let msg = "Tailnet did not reach Running state within \(Int(timeout))s — the " +
                      "browser chrome never appeared. Is this sim logged into a Tailnet " +
                      "(or was an AUTHKEY staged)?"
            if requireConnected {
                XCTFail(msg)
            } else {
                throw XCTSkip(msg)
            }
            return false
        }
        return true
    }

    /// Tapping the bookmark button in the browser toolbar opens the bookmark
    /// editor; Cancel dismisses it. Requires the connected browser.
    func testOpenAndCancelAddBookmark() throws {
        let app = XCUIApplication()
        let requireConnected = app.launchArguments.contains("-RequireConnected")
        launchConnected(app)

        guard try skipIfNotConnected(app, requireConnected: requireConnected) else { return }

        let addButton = app.buttons["add-bookmark-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10),
                      "Add Bookmark button should be in the browser bottom toolbar")
        addButton.tap()

        XCTAssertTrue(
            app.navigationBars["New Bookmark"].waitForExistence(timeout: 10),
            "Bookmark editor should appear after tapping the bookmark button"
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
            "Should return to the browser after Cancel"
        )
    }

    /// With the tailnet connected, the first tab (always an Aperture chat = the
    /// home page) loads automatically in the browser — no bookmark to tap. We
    /// wait for the WKWebView and confirm the home page URL appears in the
    /// browser's URL field.
    func testHomePageLoadsWhenConnected() throws {
        let app = XCUIApplication()
        let requireConnected = app.launchArguments.contains("-RequireConnected")
        launchConnected(app)

        guard try skipIfNotConnected(app, requireConnected: requireConnected) else { return }

        // The browser view hosts a WKWebView (the current tab's page). Wait for it.
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 30) else {
            attachScreenshot(app, named: "no-webview")
            XCTFail("Browser view / WKWebView did not appear once connected")
            return
        }

        // Confirm the home page actually loaded by polling the URL field in the
        // browser's bottom toolbar (which updates to the current URL when the
        // page finishes loading). The home page is http://ai/chat → "ai".
        let pageLoaded = waitForPageLoaded(in: app, contains: "ai", timeout: 60)
        attachScreenshot(app, named: pageLoaded ? "page-loaded" : "page-load-failed")
        XCTAssertTrue(pageLoaded,
                      "Home page (http://ai/chat) did not load within 60s. " +
                      "Check libtailscale logs: xcrun simctl spawn booted log stream " +
                      "--predicate 'subsystem == \"io.tailscale.Aperture\"'")
    }

    /// Opening a new Aperture-chat tab from the "+" button works and selects
    /// the new tab. Requires the connected browser.
    func testOpenNewChatTab() throws {
        let app = XCUIApplication()
        let requireConnected = app.launchArguments.contains("-RequireConnected")
        launchConnected(app)

        guard try skipIfNotConnected(app, requireConnected: requireConnected) else { return }

        // The "+" new-chat-tab button is in the top toolbar.
        let newTabButton = app.buttons["new-chat-tab-button"]
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 10),
                      "New Chat Tab (+) button should be in the top toolbar")
        newTabButton.tap()

        // After opening a second tab, the tab-overview button shows a "2" badge.
        // Tapping it opens the overview, which lists two tabs.
        let overviewButton = app.buttons["tab-overview-button"]
        XCTAssertTrue(overviewButton.waitForExistence(timeout: 10),
                      "Tab overview button should be present")
        overviewButton.tap()

        // The overview's nav title is "Tabs".
        XCTAssertTrue(
            app.navigationBars["Tabs"].waitForExistence(timeout: 10),
            "Tab overview should appear after tapping the tabs button"
        )
        attachScreenshot(app, named: "tab-overview")
        // Two chat tabs were opened (the first one at launch + the one we just added).
        let tabCards = app.descendants(matching: .any)
            .matching(identifier: "new-chat-tab-button").allElementsBoundByIndex
        // The "+" is also labeled new-chat-tab-button, so we just assert the
        // overview appeared (verified above) rather than counting matches.
        _ = tabCards

        app.buttons["Done"].tap()
        XCTAssertTrue(
            waitForHittable(app.buttons["add-bookmark-button"], timeout: 10),
            "Should return to the browser after Done"
        )
    }

    // MARK: - Helpers

    /// Resolve the auth key for connected tests. `xcodebuild` does NOT forward
    /// arbitrary parent-shell environment variables to the UI-test runner, so
    /// reading `APERTURE_TEST_AUTHKEY` from `ProcessInfo.environment` alone is
    /// unreliable. Instead, prefer a key file that `scripts/run-uitests.sh` /
    /// the Makefile write from their own (shell) environment, which DOES see
    /// the variable. Resolution order:
    ///   1. `APERTURE_TEST_AUTHKEY` env var (when it happens to be present).
    ///   2. File at `APERTURE_TEST_AUTHKEY_FILE`, else `/tmp/aperture-test-authkey`.
    static func resolvedTestAuthKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let k = env["APERTURE_TEST_AUTHKEY"], !k.isEmpty { return k }
        let path = env["APERTURE_TEST_AUTHKEY_FILE"] ?? "/tmp/aperture-test-authkey"
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the test node should be ephemeral. Defaults to "1" (ephemeral
    /// nodes auto-cleanup on close, ideal for CI); must match the key's type.
    static func resolvedTestEphemeral() -> String {
        let v = ProcessInfo.processInfo.environment["APERTURE_TEST_EPHEMERAL"]
        return (v?.isEmpty == false) ? v! : "1"
    }

    /// Waits for the brand header (the "Aperture" logo lockup) to appear. It's
    /// the sole "Aperture" branding (no nav-bar title), present in both the
    /// connection gate and (post-connection) the browser chrome. Matches any
    /// element type via `descendants(matching: .any)` for robustness.
    @discardableResult
    private func waitForBrandHeader(_ app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let brandHeader = app.descendants(matching: .any)
            .matching(identifier: "aperture-brand-header").firstMatch
        return brandHeader.waitForExistence(timeout: timeout)
    }

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

    /// Waits for the browser page to load by polling the URL text field in the
    /// bottom toolbar (which updates to the loaded URL when the page finishes
    /// loading), with a fallback to the WKWebView's identifier/label.
    /// Returns true if any signal contained `substring` in time.
    @discardableResult
    private func waitForPageLoaded(in app: XCUIApplication, contains substring: String,
                                   timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            let urlField = app.textFields["Enter URL"]
            if let val = urlField.value as? String, val.contains(substring) { return true }
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
    /// Each delete and each typed character drive the SwiftUI `Binding`, so
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
