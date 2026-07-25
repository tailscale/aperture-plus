//  Created by Jonathan Nobels on 2025-12-18.
//

import AuthenticationServices

@MainActor
final class AuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    private var authSession: ASWebAuthenticationSession?

    func showAuth(authURL: String) {
        guard let url = URL(string: authURL) else {
            logger.log("AuthManager.showAuth: invalid URL: \(authURL)")
            return
        }


        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, error in
            // Log EVERY outcome (not just canceledLogin) so a real-device
            // session where the sheet fails to present / immediately dismisses
            // is visible in Console.app, not silent.
            if let error {
                logger.log("Auth session ended with error: \(error)")
            } else {
                logger.log("Auth session completed (callback received)")
            }
        }

        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self

        self.authSession = session
        let started = session.start()
        // start() returns false if presentation can't begin (no anchor, not
        // foregrounded, …) — surface that so "tap Login, nothing happens" is
        // debuggable instead of silent.
        logger.log("AuthManager.showAuth: session.start() -> \(started) for \(authURL)")
    }

    func cancel() {
        self.authSession?.cancel()
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
