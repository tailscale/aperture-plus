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
//    working tailnet connection. They authenticate non-interactively via an
//    auth key when one is staged (see `resolvedTestAuthKey`), and otherwise
//    they FAIL (never skip) — a broken connection must be a loud failure, not
//    a silent green. Stage a key at ~/.aperture-ios-authkey (or pass
//    AUTHKEY=... / set APERTURE_TEST_AUTHKEY).
//
//  Run from the command line:
//
//    make test                                # stages ~/.aperture-ios-authkey if present
//    make test AUTHKEY=tskey-auth-...         # explicit key
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

    // MARK: - Crash-capture test (connection-independent)

    /// Verifies that Go runtime panic output is captured to the redirected
    /// stderr log and surfaced on the next launch — the experiment that makes
    /// the next overnight TestFlight crash readable.
    ///
    /// Uses mode 2 (`-CrashTest -CrashTestMode 2`), which writes a realistic
    /// Go-panic dump to stderr (fd 2) and RETURNS without aborting. The real
    /// abort path (modes 0/1) is covered by the host-side `make crashtest`
    /// script; here we can't let the app actually crash because XCUITest
    /// hard-fails any test whose app crashes ("io.tailscale.Aperture crashed"),
    /// which would abort the test before phase 2. Mode 2 exercises the exact
    /// same capture+surface pipeline (dup2 → stderr.log → next-launch os_log +
    /// `crash-capture-status` label) without killing the process.
    ///
    /// Phase 1: launch with `-CrashTest -CrashTestMode 2`. The app writes the
    /// panic dump to stderr.log, then continues running normally. We confirm
    /// it stayed up (brand header), give the async start task time to write,
    /// then terminate cleanly.
    ///
    /// Phase 2: relaunch with `-UITestCrashReport`. CrashCapture.start() sees
    /// the previous run's stderr.log, finds the first crash-signature line, and
    /// surfaces it under `crash-capture-status`. We assert it carries our panic.
    func testGoPanicIsCapturedToStderrLog() throws {
        let app = XCUIApplication()

        // --- Phase 1: write the panic dump to stderr.log (no crash) ---
        app.launchArguments = ["-UITestResetLogin", "-UITestClearCrashLogs",
                               "-CrashTest", "-CrashTestMode", "2"]
        app.launch()
        XCTAssertTrue(waitForBrandHeader(app, timeout: 20),
                      "App should launch and stay up under -CrashTestMode 2 (it " +
                      "writes the panic dump but does not abort)")
        // The panic dump is written from the async start task shortly after
        // launch; give it time before we tear the app down.
        _ = XCTWaiter().wait(for: [], timeout: 6)
        app.terminate()

        // --- Phase 2: relaunch and read back the captured panic ---
        app.launchArguments = ["-UITestResetLogin", "-UITestCrashReport"]
        app.launch()

        let status = app.staticTexts["crash-capture-status"]
        let appeared = status.waitForExistence(timeout: 20)
        if !appeared { attachScreenshot(app, named: "crashtest-no-report-label") }
        XCTAssertTrue(appeared,
                      "The crash-capture debug label should appear under " +
                      "-UITestCrashReport. If it's missing or reads 'NO CAPTURE', " +
                      "CrashCapture didn't surface the previous run's stderr.log.")

        let label = status.label
        attachScreenshot(app, named: label.contains("TsnetCrashTest") ? "crashtest-captured" : "crashtest-not-captured")
        XCTAssertTrue(label.contains("panic"),
                      "Captured status should contain 'panic'; got: \(label)")
        XCTAssertTrue(label.contains("TsnetCrashTest"),
                      "Captured status should contain 'TsnetCrashTest' (the " +
                      "panic we induced); got: \(label)")
    }

    /// Polls `app.state` until the app is not running (crashed/terminated),
    /// up to `timeout`. Reading `.state` is not a UI interaction, so it doesn't
    /// itself trip XCUITest's crash detector the way a tap/query would.
    /// (Kept for the host-side `make crashtest` flow; unused by mode 2 above.)
    @discardableResult
    private func waitForAppNotRunning(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            return app.state == .notRunning
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
        // We do NOT restore by typing `originalValue` back into the field:
        // `clearAndType`'s fixed-count delete clear is unreliable on longer
        // strings, and a partial clear concatenates the typed text with
        // leftover suffix from the old value (e.g. `http://ai/chat` +
        // `FADC5F69` = `http://ai/chatFADC5F69`), writing a corrupted URL to
        // UserDefaults that then makes every later connected test load a
        // bogus path and 404. Instead, relaunch with `-UITestResetHomePage`,
        // which resets each workspace's home page to the default at launch —
        // 100% reliable, no typing. (The persistence-under-typing claim was
        // already verified above; the restore is just cleanup.)
        app.launchArguments = ["-UITestResetHomePage", "-UITestResetLogin"]
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForBrandHeader(app, timeout: 20),
                      "App should relaunch after home-page reset")
        // Verify the reset took: the home page field should show the default.
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let restoredField = app.textFields["home-page-field"]
        XCTAssertTrue(restoredField.waitForExistence(timeout: 10))
        XCTAssertEqual((restoredField.value as? String) ?? "", "http://ai/chat",
                       "Home page should be restored to the default after the reset relaunch")
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
        // Reset the home page to the known default so connected tests are
        // hermetic — a prior test (e.g. the persistence test) may have left a
        // non-default value in UserDefaults, and the first tab always loads
        // HomePage.standard.url, so a stale value would load the wrong URL.
        // (Now per-workspace; `-UITestResetHomePage` resets them all.)
        app.launchArguments += ["-UITestResetHomePage"]
        app.launch()
    }

    /// Waits for the connected browser to appear and FAILS (never skips) if it
    /// doesn't. Connected tests require a working tailnet connection — a broken
    /// connection must be a loud failure, never a silent skip. The connection
    /// is automated by staging an auth key (see `launchConnected` /
    /// `resolvedTestAuthKey`); without one, a fresh sim won't connect and this
    /// fails after the timeout.
    @discardableResult
    private func requireBrowserReady(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        guard waitForBrowserReady(app, timeout: timeout) else {
            attachScreenshot(app, named: "not-connected")
            XCTFail(
                "Tailnet did not reach Running state within \(Int(timeout))s — the " +
                "browser chrome never appeared. Connected tests require a connection. " +
                "Stage an auth key at ~/.aperture-ios-authkey (or pass AUTHKEY=... / " +
                "set APERTURE_TEST_AUTHKEY); on a not-logged-in sim without a key the " +
                "node can't authenticate. This is a hard failure by design — connected " +
                "tests never skip, so a broken connection is never silent.")
            return false
        }
        return true
    }

    /// Tapping the bookmark button in the browser toolbar opens the bookmark
    /// editor; Cancel dismisses it. Requires the connected browser.
    func testOpenAndCancelAddBookmark() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        let addButton = app.buttons["add-bookmark-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10),
                      "Add Bookmark button should be in the browser bottom toolbar")
        addButton.tap()

        XCTAssertTrue(
            app.navigationBars["New Bookmark"].waitForExistence(timeout: 10),
            "Bookmark editor should appear after tapping the bookmark button"
        )

        // The editor opens pre-filled with the current page's title + URL
        // (it's "bookmark this page"), so Save starts ENABLED. Clear both
        // fields and confirm Save becomes disabled — the original intent of
        // this assertion (empty name+url => can't save).
        let nameField = app.textFields["bookmark-name-field"]
        let urlField = app.textFields["bookmark-url-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Name field should exist")
        XCTAssertTrue(urlField.exists, "URL field should exist")
        let saveButton = app.buttons["bookmark-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button should exist")

        nameField.clearAndType(text: "")
        urlField.clearAndType(text: "")
        XCTAssertFalse(saveButton.isEnabled,
                       "Save should be disabled when name+url are empty")

        // Typing valid values should re-enable Save.
        nameField.clearAndType(text: "Test Bookmark")
        urlField.clearAndType(text: "http://ai/chat")
        XCTAssertTrue(saveButton.isEnabled,
                      "Save should be enabled once name+url are valid")

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
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        // The browser view hosts a WKWebView (the current tab's page). Wait for it.
        let webView = app.webViews.firstMatch
        guard webView.waitForExistence(timeout: 30) else {
            attachScreenshot(app, named: "no-webview")
            XCTFail("Browser view / WKWebView did not appear once connected")
            return
        }

        // Confirm the home page URL was reached AND no navigation error
        // surfaced. We check the URL pill/host (the navigation reached the
        // server) rather than specific page content. The thing we must catch
        // is a *navigation failure* (cert/connectivity/proxy), which surfaces
        // the `nav-error-overlay`. So: reach the URL, then assert the error
        // overlay did NOT appear. (A 404 would be a *successful* load from
        // WebKit's view — but the 404 flakiness was a test-isolation bug, now
        // fixed: see testHomePageSettingPersistsAcrossSettingsReopen.)
        let reached = waitForPageLoaded(in: app, contains: "ai", timeout: 60)
        attachScreenshot(app, named: reached ? "page-loaded" : "page-load-failed")
        XCTAssertTrue(reached,
                      "Home page (http://ai/chat) URL was not reached within 60s. " +
                      "Check libtailscale logs: xcrun simctl spawn booted log stream " +
                      "--predicate 'subsystem == \"io.tailscale.Aperture\"'")
        let errorOverlay = app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch
        // A navigation failure (e.g. the TLS cert trust failure this fixes)
        // surfaces the overlay quickly; give it a moment, then require absence.
        let overlayAppeared = errorOverlay.waitForExistence(timeout: 5)
        if overlayAppeared { attachScreenshot(app, named: "homepage-nav-error") }
        XCTAssertFalse(overlayAppeared,
                       "Home page load failed with a navigation error (cert/connectivity). " +
                       "The error overlay should not appear for a successful load.")
    }


    /// Opening a new Aperture-chat tab from the "+" button works and selects
    /// the new tab. Requires the connected browser.
    func testOpenNewChatTab() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

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

        // Guard the tab-title-mirroring fix (#5b): each card should show the
        // real page title (the Aperture chat UI → "...Aperture Chat..."), not
        // the host fallback ("ai"). The title is set by the SPA after load, so
        // poll for it. (Both tabs load the same home page.)
        let titleAppeared = waitForTabCardTitle(in: app, contains: "Aperture", timeout: 30)
        attachScreenshot(app, named: titleAppeared ? "tab-titles" : "tab-titles-missing")
        XCTAssertTrue(titleAppeared,
                      "Tab cards should show the real page title (\"...Aperture " +
                      "Chat...\"), not the host fallback (\"ai\") — the SPA title " +
                      "update must be mirrored into the tab chrome.")

        app.buttons["Done"].tap()
        XCTAssertTrue(
            waitForHittable(app.buttons["add-bookmark-button"], timeout: 10),
            "Should return to the browser after Done"
        )
    }

    /// The per-tab connection-type indicator (#5) classifies the current page.
    /// After the home page (http://ai/chat) loads on the tailnet, the host "ai"
    /// is a tailnet peer, so the indicator must NOT read "Internet (off
    /// tailnet)" — it should be "Direct tailnet connection" or "Tailnet
    /// connection via relay". Guards the ConnectionTypeResolver + the
    /// backendStatus poll + the icon rendering. Requires the connected browser.
    func testConnectionTypeIndicatorNotInternet() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        // Wait for the home page to load, then poll for the indicator to flip
        // off "internet" (the default before the status poll runs).
        let internet = "Internet (off tailnet)"
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            // The indicator is an accessibility element with one of three labels.
            // After the home page loads on the tailnet it must not be "internet".
            let labels: [String] = [
                "Direct tailnet connection",
                "Tailnet connection via relay"
            ]
            for label in labels {
                if app.descendants(matching: .any).matching(identifier: label).firstMatch.exists {
                    return true
                }
            }
            return false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        let result = XCTWaiter().wait(for: [expectation], timeout: 60)
        attachScreenshot(app, named: result == .completed ? "conn-type-tailnet" : "conn-type-stuck-internet")
        XCTAssertTrue(result == .completed,
                      "The connection-type indicator should classify the home page (" +
                      "http://ai/chat, a tailnet peer) as direct or derped, not " +
                      "\(internet). The backendStatus poll may not be running.")
    }

    /// Loading a URL that can't be reached surfaces the navigation-error
    /// overlay ("Unable to Load Page"), proving the error plumbing works for
    /// user-typed URLs. Requires the connected browser (auth key automates
    /// login). Previously the URL bar called `page.load` without watching the
    /// navigation's async sequence, so failures were silent.
    func testBadURLShowsErrorOverlay() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        // Enter the URL editor. On iPhone (compact) tap the url-pill; the
        // editing bar's text field ("url-field") appears. (On iPad the
        // "Enter URL" field is always present.)
        if app.buttons["url-pill"].waitForExistence(timeout: 5) {
            app.buttons["url-pill"].tap()
        }
        let urlField = app.textFields["url-field"].firstMatch
        if !urlField.exists {
            // Regular layout fallback.
            app.textFields["Enter URL"].firstMatch.tap()
        }
        XCTAssertTrue(urlField.waitForExistence(timeout: 10),
                      "URL field should be reachable in the browser toolbar")
        urlField.tap()

        // A host under .invalid can never resolve, so the provisional
        // navigation through the SOCKS5 proxy must fail.
        let badURL = "http://nonexistent-aperture-test.invalid/"
        urlField.clearAndType(text: badURL)
        urlField.typeText("\n")

        let overlay = app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch
        let appeared = overlay.waitForExistence(timeout: 30)
        attachScreenshot(app, named: appeared ? "nav-error-shown" : "nav-error-missing")
        XCTAssertTrue(appeared,
                      "Loading an unreachable URL (\(badURL)) should show the " +
                      "navigation-error overlay")
    }

    /// Explicitly loading **HTTPS** at a hostname whose certificate is issued
    /// for a *different* name (the tailnet FQDN, not the bare MagicDNS name)
    /// must fail with a certificate error — proving TLS certificate
    /// verification is intact and NOT bypassed. This guards the design choice
    /// (we disable WebKit's HTTP→HTTPS *upgrade*, but never bypass cert
    /// checks): `http://ai/` loads fine over plain HTTP, while `https://ai/`
    /// (cert mismatch) correctly errors. Requires the connected browser.
    func testHTTPSCertMismatchShowsError() throws {
        let app = XCUIApplication()
        launchConnected(app)

        guard requireBrowserReady(app) else { return }

        // Open the URL editor (compact: tap the url-pill; regular: tap the field).
        if app.buttons["url-pill"].waitForExistence(timeout: 5) {
            app.buttons["url-pill"].tap()
        }
        let urlField = app.textFields["url-field"].firstMatch
        if !urlField.exists {
            app.textFields["Enter URL"].firstMatch.tap()
        }
        XCTAssertTrue(urlField.waitForExistence(timeout: 10),
                      "URL field should be reachable in the browser toolbar")
        urlField.tap()

        // https://ai/ — the `ai` node's cert is for ai.<tailnet>.ts.net, so
        // the TLS handshake must fail on hostname mismatch (-1202) before any
        // HTTP-level redirect can occur.
        urlField.clearAndType(text: "https://ai/")
        urlField.typeText("\n")

        let overlay = app.descendants(matching: .any)
            .matching(identifier: "nav-error-overlay").firstMatch
        let appeared = overlay.waitForExistence(timeout: 30)
        attachScreenshot(app, named: appeared ? "cert-error-shown" : "cert-error-missing")
        XCTAssertTrue(appeared,
                      "Loading https://ai/ (cert issued for the FQDN, not the " +
                      "bare name) should fail with a certificate error. If this " +
                      "load *succeeds*, TLS cert verification has been bypassed " +
                      "— that is a security regression.")
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

    /// Waits for at least one tab-overview card to show a title containing
    /// `substring` (the cards' title text is the page title, mirrored from the
    /// WebPage). Guards the tab-title-mirroring fix (#5b) — a regression would
    /// leave cards showing the host fallback (e.g. "ai") instead of the real
    /// SPA title.
    @discardableResult
    private func waitForTabCardTitle(in app: XCUIApplication, contains substring: String,
                                     timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            // Tab-overview cards expose their title as a static text. Match any
            // static text whose label contains the substring and is plausible as
            // a card title (non-trivial length).
            let texts = app.staticTexts.allElementsBoundByIndex
            return texts.contains { $0.label.localizedCaseInsensitiveContains(substring) }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the browser page to load by polling several native signals
    /// across both layouts:
    ///   - the compact URL pill's accessibility label ("Address: <host>") —
    ///     iPhone non-editing,
    ///   - the URL text field's value ("Enter URL" on iPad / "url-field" when
    ///     editing on iPhone),
    ///   - the WKWebView's identifier/label as a fallback.
    /// Returns true if any signal contained `substring` in time.
    @discardableResult
    private func waitForPageLoaded(in app: XCUIApplication, contains substring: String,
                                   timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { obj, _ -> Bool in
            guard let app = obj as? XCUIApplication else { return false }
            // Compact URL pill (button) label: "Address: <host>".
            let pill = app.buttons["url-pill"]
            if pill.exists, pill.label.contains(substring) { return true }
            // URL text fields (either layout).
            for id in ["Enter URL", "url-field"] {
                let f = app.textFields[id]
                if let val = f.value as? String, val.contains(substring) { return true }
            }
            // Fallback: the WKWebView's identifier/label.
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
