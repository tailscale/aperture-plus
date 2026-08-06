import XCTest

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

    /// Connection-independent coverage for the native auth presentation path:
    /// wait for NeedsLogin, press Login, and assert AuthenticationServices
    /// presents web content without trapping or terminating the app.
    func testLoginPresentsAuthenticationWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-UITestResetLogin"]
        app.launch()

        let login = app.buttons["login-button"]
        XCTAssertTrue(login.waitForExistence(timeout: 90))
        login.click()

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 90),
                      "Login should present AuthenticationServices web content")
        XCTAssertEqual(app.state, .runningForeground,
                       "Presenting login must not trap or terminate the native app")
    }

    /// Auth-key login gives deterministic connected/logout coverage without
    /// driving a third-party identity provider. The workspace is then deleted
    /// through Settings and replaced by a fresh workspace needing login.
    func testAuthKeyLoginAndLogout() throws {
        guard let authKey = Self.stagedAuthKey() else {
            throw XCTSkip("Stage ~/.aperture-ios-authkey for connected Mac UI coverage")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-UITestResetWorkspaces", "-UITestResetHomePage"]
        app.launchEnvironment["APERTURE_AUTHKEY"] = authKey
        app.launchEnvironment["APERTURE_EPHEMERAL"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["more-menu-button"].waitForExistence(timeout: 120),
                      "Auth-key node should reach the connected browser")
        app.buttons["more-menu-button"].click()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].click()

        let logout = app.buttons["logout-button"]
        XCTAssertTrue(logout.waitForExistence(timeout: 10))
        logout.click()
        let confirmation = app.sheets.buttons["Logout"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.click()

        XCTAssertTrue(app.buttons["login-button"].waitForExistence(timeout: 90),
                      "Logout should replace the deleted workspace with one needing login")
    }

    private static func stagedAuthKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aperture-ios-authkey")
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
