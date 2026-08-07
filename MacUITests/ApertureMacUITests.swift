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

    /// Native interactive Login → Logout → Relogin, driving the real
    /// AuthenticationServices web flow against Tailscale + nullid.fly.dev.
    /// This covers both completion paths that previously trapped on macOS when
    /// AuthenticationServices called a MainActor closure on its XPC queue.
    func testInteractiveLoginLogoutRelogin() throws {
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
        let emailField = app.webViews.textFields.firstMatch
        guard emailField.waitForExistence(timeout: emailFieldTimeout) else { return false }
        emailField.click()
        emailField.typeText("testuser@nullid.fly.dev")

        let signIn = app.webViews.buttons["Sign in"]
        if signIn.waitForExistence(timeout: 10) {
            signIn.click()
        } else {
            emailField.typeKey(.return, modifierFlags: [])
        }

        let nullidConfirm = app.webViews.buttons["Log in"]
        guard nullidConfirm.waitForExistence(timeout: 20) else { return false }
        nullidConfirm.click()

        let connect = app.webViews.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Connect")
        ).firstMatch
        if connect.waitForExistence(timeout: 20) { connect.click() }
        return true
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
            if app.descendants(matching: .any)["connected-browser"].exists { return true }

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
