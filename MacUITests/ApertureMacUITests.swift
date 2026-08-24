// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

import XCTest
import AppIntents

@MainActor
final class ApertureMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Native window semantics: Command-N creates a persisted workspace in its
    /// own window; closing that window doesn't terminate the original window.
    func testCommandNOpensSeparateWorkspaceWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("n", modifierFlags: .command)
        let twoWindows = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 2"),
            object: app.windows
        )
        XCTAssertEqual(XCTWaiter().wait(for: [twoWindows], timeout: 30), .completed,
                       "Command-N should create a workspace in a second native window")

        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        let oneWindow = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 1"),
            object: app.windows
        )
        XCTAssertEqual(XCTWaiter().wait(for: [oneWindow], timeout: 10), .completed)
    }

    /// Shared Settings and tab-overview sheets remain useful before login,
    /// while the native Mac tab overview deliberately has no iOS workspace
    /// selector (workspace windows are listed in the Window menu instead).
    func testNoLoginSettingsAndTabOverview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-UITestResetLogin"]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        XCTAssertTrue(app.textFields["home-page-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["routing-test-field"].waitForExistence(timeout: 5),
                      "The shared routing diagnostic should be available before login")
        app.buttons["settings-done-button"].click()

        let tabs = app.buttons["tab-overview-button"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.click()
        XCTAssertTrue(app.staticTexts["Tabs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["session-selector-menu"].exists,
                       "Native Mac tab overview must not duplicate the Window-menu workspace switcher")
        app.buttons["Done"].click()
    }

    /// Desktop browser chrome and application menu commands operate on the
    /// focused native workspace window. Uses auth-key login so this remains
    /// deterministic and independent of the external browser auth flow.
    func testDesktopTabsAndBrowserCommands() throws {
        guard let authKey = Self.stagedAuthKey() else {
            XCTFail("Required auth key is missing. Stage ~/.aperture-ios-authkey or /tmp/aperture-test-authkey.")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", "https://example.com/",
        ]
        app.launchEnvironment["APERTURE_AUTHKEY"] = authKey
        app.launchEnvironment["APERTURE_EPHEMERAL"] = "1"
        app.launch()

        XCTAssertTrue(waitForBrowserOrFail(app, timeout: 20))
        XCTAssertTrue(app.buttons["url-pill"].waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForCount(app.buttons.matching(identifier: "tab-chip"), atLeast: 2, timeout: 5),
                      "Command-T should add a visible desktop tab")

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["url-field"].waitForExistence(timeout: 5),
                      "Command-L should focus the shared address field")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForCount(app.buttons.matching(identifier: "tab-chip"), exactly: 1, timeout: 5),
                      "Command-W should close a tab, not its workspace window")
        XCTAssertEqual(app.windows.count, 1)

        let addBookmark = app.buttons["add-bookmark-button"]
        XCTAssertTrue(addBookmark.waitForExistence(timeout: 5))
        addBookmark.click()
        XCTAssertTrue(app.textFields["bookmark-name-field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["bookmark-url-field"].exists)
        app.buttons["bookmark-cancel-button"].click()
    }

    /// Native interactive Login → Logout → Relogin, driving the real
    /// AuthenticationServices web flow against Tailscale + nullid.fly.dev.
    /// This covers both completion paths that previously trapped on macOS when
    /// AuthenticationServices called a MainActor closure on its XPC queue.
    func testInteractiveLoginLogoutRelogin() throws {
        closeStaleSafariAuthenticationWindows()
        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces", "-UITestResetLogin",
            "-UITestHomePage", "https://example.com/",
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        let login = app.buttons["login-button"]
        XCTAssertTrue(login.waitForExistence(timeout: 30))
        login.click()

        XCTAssertTrue(completeNullIdLogin(app, emailFieldTimeout: 30),
                      "Initial native Mac interactive login should complete")
        XCTAssertTrue(waitForBrowserOrFail(app, timeout: 30),
                      "Connected browser should appear after interactive login")
        XCTAssertEqual(app.state, .runningForeground)

        XCTAssertTrue(openSettings(app))
        let logout = app.buttons["logout-button"]
        XCTAssertTrue(logout.waitForExistence(timeout: 10))
        logout.click()
        let confirmation = app.sheets.buttons["Logout"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.click()

        let relogin = app.buttons["login-button"]
        XCTAssertTrue(relogin.waitForExistence(timeout: 30),
                      "Replacement workspace should require login")
        relogin.click()
        XCTAssertTrue(completeNullIdLogin(app, emailFieldTimeout: 30),
                      "Native Mac relogin should complete")
        XCTAssertTrue(waitForBrowserOrFail(app, timeout: 30))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Auth-key login gives deterministic connected/logout coverage without
    /// driving a third-party identity provider.
    func testAuthKeyLoginAndLogout() throws {
        guard let authKey = Self.stagedAuthKey() else {
            XCTFail("Required auth key is missing. Stage ~/.aperture-ios-authkey or /tmp/aperture-test-authkey.")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestResetWorkspaces",
            "-UITestHomePage", "https://example.com/",
        ]
        app.launchEnvironment["APERTURE_AUTHKEY"] = authKey
        app.launchEnvironment["APERTURE_EPHEMERAL"] = "1"
        app.launch()

        XCTAssertTrue(waitForBrowserOrFail(app, timeout: 20),
                      "Auth-key node should reach the connected browser")
        XCTAssertTrue(openSettings(app))

        let logout = app.buttons["logout-button"]
        XCTAssertTrue(logout.waitForExistence(timeout: 10))
        logout.click()
        let confirmation = app.sheets.buttons["Logout"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.click()

        XCTAssertTrue(waitForBrowserOrFail(app, timeout: 20),
                      "Logout should replace the deleted workspace and the inherited auth key should reconnect it")
    }

    private func completeNullIdLogin(_ app: XCUIApplication,
                                     emailFieldTimeout: TimeInterval) -> Bool {
        // On macOS, ASWebAuthenticationSession presents its private browsing
        // window in Safari, not in Aperture's process. Query that application
        // explicitly; `app.webViews` can only ever see Aperture's own page.
        let authApp = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        let emailField = authApp.webViews.textFields.firstMatch
        guard emailField.waitForExistence(timeout: emailFieldTimeout) else { return false }
        emailField.click()
        emailField.typeText("testuser@nullid.fly.dev")

        let signIn = authApp.webViews.buttons["Sign in"]
        if signIn.waitForExistence(timeout: 10) {
            signIn.click()
        } else {
            emailField.typeKey(.return, modifierFlags: [])
        }

        let nullidConfirm = authApp.webViews.buttons["Log in"]
        guard nullidConfirm.waitForExistence(timeout: 20) else { return false }
        nullidConfirm.click()

        let connect = authApp.webViews.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Connect")
        ).firstMatch
        // The null-id confirmation submits the login. Depending on control-
        // plane state, Tailscale either associates the waiting node directly
        // or shows an additional device-authorization button. Never click an
        // arbitrary first button from a transient page; only click the
        // explicit Connect action when it appears.
        if connect.waitForExistence(timeout: 5) { connect.click() }

        // Give the authorization POST a moment to leave Safari before putting
        // Aperture back in front. LoginFinished remains the authoritative
        // success signal checked by waitForBrowserOrFail.
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        return true
    }

    private func closeStaleSafariAuthenticationWindows() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        guard safari.state != .notRunning else { return }
        // ASWebAuthenticationSession's private windows are not reliably
        // represented in `safari.windows` until they are key, so matching and
        // closing by title can miss a stale welcome page. Terminating Safari
        // is deterministic; AuthenticationServices launches a clean private
        // window for the new session on demand.
        safari.terminate()
    }

    /// Poll several mutually-exclusive states so a terminal error fails in a
    /// few hundred milliseconds rather than being hidden behind a long wait on
    /// one button. The short sleep keeps the test responsive and the total
    /// timeout is an explicit upper bound, not a stack of serial waits.
    private func waitForBrowserOrFail(_ app: XCUIApplication,
                                      timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == .notRunning { return false }
            // The connected browser is up when its chrome appears. The
            // `connected-browser` overlay is an opacity-0.01 Text that AppKit
            // does not surface in the accessibility tree, so it can't be the
            // signal. Instead look for a real, browser-only toolbar control.
            // `new-chat-tab-button` (the "+") lives only in CompactBrowserToolbar,
            // never in ConnectionGateView, and is a Button — reliably surfaced.
            if app.buttons["new-chat-tab-button"].exists { return true }
            // `url-pill` is the other always-present browser-only control; a
            // fallback in case the "+" is momentarily disabled/off-screen.
            if app.buttons["url-pill"].exists { return true }

            let errorPage = app.descendants(matching: .any)
                .matching(identifier: "nav-error-overlay").firstMatch
            if errorPage.exists {
                let detail = errorPage.staticTexts.allElementsBoundByIndex
                    .map { element in
                        let label = element.label
                        if !label.isEmpty { return label }
                        return element.value as? String ?? ""
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: " | ")
                XCTFail("Browser reached a terminal navigation error: \(detail)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // Timeout — emit diagnostics so a missing-window or stuck-gate failure
        // is diagnosable from the test log without a screenshot.
        print("waitForBrowserOrFail TIMEOUT after \(timeout)s: "
              + "app.state=\(app.state.rawValue) windows=\(app.windows.count) "
              + "login=\(app.buttons["login-button"].exists) "
              + "newtab=\(app.buttons["new-chat-tab-button"].exists) "
              + "url-pill=\(app.buttons["url-pill"].exists) "
              + "settings=\(app.buttons["settings-button"].exists)")
        return false
    }

    private func waitForCount(_ query: XCUIElementQuery,
                              atLeast minimum: Int? = nil,
                              exactly expected: Int? = nil,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = query.count
            if let expected, count == expected { return true }
            if let minimum, count >= minimum { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func openSettings(_ app: XCUIApplication) -> Bool {
        let settings = app.buttons["settings-button"]
        guard settings.waitForExistence(timeout: 2) else { return false }
        settings.click()
        return true
    }

    private static func stagedAuthKey() -> String? {
        // A macOS UI-test runner has a sandbox container home, not the login
        // user's home. Prefer the same /tmp staging path as the iOS runner;
        // fall back to ~/.aperture-ios-authkey for unsandboxed local runs.
        let candidates = [
            URL(fileURLWithPath: ProcessInfo.processInfo.environment[
                "APERTURE_TEST_AUTHKEY_FILE"] ?? "/tmp/aperture-test-authkey"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aperture-ios-authkey"),
        ]
        for url in candidates {
            if let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
