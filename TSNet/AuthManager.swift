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


        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ipnauth") { [weak self] callbackURL, error in
            // The Tailscale login URL normally completes out-of-band through
            // the control plane, so LoginFinished (not this callback) is the
            // authoritative success signal. Keep the callback for cancellation
            // and diagnostics; using Tailscale's callback scheme also lets any
            // future redirect complete the session normally.
            let elapsed = self?.elapsedDescription() ?? "unknown"
            if let error {
                logger.log("Auth session ended after \(elapsed) with error: \(error)")
            } else {
                logger.log("Auth session completed after \(elapsed), callback=\(callbackURL?.absoluteString ?? "nil")")
            }
            self?.authSession = nil
            self?.startedAt = nil
            let ended = self?.sessionEnded
            self?.sessionEnded = nil
            ended?()
        }

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
        // A zero-frame anchor makes the auth sheet present invisibly (or not
        // at all) — `session.start()` can return true yet nothing appears.
        // Log it loudly so a cold-launch "tap Login, nothing happens" is
        // diagnosable instead of silent.
        logger.log("AuthManager presentationAnchor: NO UIWindowScene connected; auth sheet will be invisible!")
        return ASPresentationAnchor(frame: .zero)
    }

}
