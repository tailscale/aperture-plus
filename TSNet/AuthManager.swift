//  Created by Jonathan Nobels on 2025-12-18.
//

import AuthenticationServices

@MainActor
final class AuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var authSession: ASWebAuthenticationSession?
    private var startedAt: ContinuousClock.Instant?
    private var sessionEnded: (() -> Void)?

    func showAuth(authURL: String, onEnded: @escaping () -> Void = {}) {
        guard let url = URL(string: authURL) else {
            logger.log("AuthManager.showAuth: invalid URL: \(authURL)")
            return
        }


        // Build this closure in a nonisolated context. A closure literal made
        // directly in this @MainActor method inherits MainActor isolation, so
        // AuthenticationServices' private XPC queue traps at closure ENTRY —
        // before a Task hop inside the body can run.
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "ipnauth",
            completionHandler: Self.makeCompletion(for: self)
        )

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self

        self.authSession = session
        sessionEnded = onEnded
        startedAt = ContinuousClock.now
        let started = session.start()
        // start() returns false if presentation can't begin (no anchor, not
        // foregrounded, …) — surface that so "tap Login, nothing happens" is
        // debuggable instead of silent.
        logger.log("AuthManager.showAuth: session.start() -> \(started) for \(authURL)")
    }

    nonisolated private static func makeCompletion(
        for manager: AuthManager
    ) -> @Sendable (URL?, Error?) -> Void {
        { [weak manager] callbackURL, error in
            // Reduce Foundation objects to Sendable values before crossing to
            // MainActor. AuthenticationServices is free to invoke this on any
            // queue on both iOS and macOS.
            let callback = callbackURL?.absoluteString
            let errorDescription = error.map(String.init(describing:))
            Task { @MainActor [weak manager] in
                manager?.authenticationSessionEnded(
                    callback: callback,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func authenticationSessionEnded(
        callback: String?,
        errorDescription: String?
    ) {
        // The Tailscale login URL normally completes out-of-band through the
        // control plane, so LoginFinished (not this callback) is authoritative.
        let elapsed = elapsedDescription()
        if let errorDescription {
            logger.log("Auth session ended after \(elapsed) with error: \(errorDescription)")
        } else {
            logger.log("Auth session completed after \(elapsed), callback=\(callback ?? "nil")")
        }
        authSession = nil
        startedAt = nil
        let ended = sessionEnded
        sessionEnded = nil
        ended?()
    }

    func authenticationSucceeded() {
        guard authSession != nil else {
            logger.log("AuthManager: LoginFinished received with no active auth session")
            return
        }
        logger.log("AuthManager: LoginFinished after \(elapsedDescription()); cancelling auth session")
        sessionEnded = nil
        authSession?.cancel()
        authSession = nil
        startedAt = nil
    }

    func cancel(reason: String = "state left NeedsLogin") {
        guard authSession != nil else { return }
        logger.log("AuthManager: cancelling after \(elapsedDescription()); reason=\(reason)")
        sessionEnded = nil
        authSession?.cancel()
        authSession = nil
        startedAt = nil
    }

    private func elapsedDescription() -> String {
        guard let startedAt else { return "unknown" }
        let duration = startedAt.duration(to: .now)
        return String(format: "%.3fs", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if canImport(UIKit)
        // Prefer the key window; fall back to the first connected window scene;
        // only as a last resort return a frameless window. The previous code
        // force-unwrapped `connectedScenes.first as! UIWindowScene`, which
        // crashes if there's no window scene (e.g. showAuth called before the
        // scene is attached, or all scenes disconnected) — a crash mid-login is
        // worse than a failed sheet presentation.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            logger.log("AuthManager presentationAnchor: key window \(key.frame)")
            return key
        }
        if let scene = scenes.first {
            logger.log("AuthManager presentationAnchor: no key window; using first scene")
            return ASPresentationAnchor(windowScene: scene)
        }
        // AuthenticationServices asks for its anchor only after `start()` from
        // a visible button action, so at least one connected scene is an API
        // invariant here. Avoid the deprecated frameless UIWindow fallback;
        // failing loudly is preferable to returning an anchor that can only
        // produce an invisible authentication sheet.
        preconditionFailure("AuthManager presentationAnchor requested with no connected UIWindowScene")
#else
        if let key = NSApplication.shared.keyWindow {
            logger.log("AuthManager presentationAnchor: key Mac window \(key.frame)")
            return key
        }
        if let window = NSApplication.shared.windows.first {
            logger.log("AuthManager presentationAnchor: no key Mac window; using first window")
            return window
        }
        logger.log("AuthManager presentationAnchor: NO NSWindow connected; using fallback window")
        return ASPresentationAnchor()
#endif
    }

}
