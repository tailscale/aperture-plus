// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//  Created by Jonathan Nobels on 2025-12-18.
//


import Combine
import TailscaleKit
import SwiftUI

final class StatusViewModel:  ObservableObject {
    @Published var statusText: String = ""
    @Published var statusIconName: String = "questionmark.circle"
    @Published var needsAuth: Bool = false
    @Published var running: Bool = false
    @Published var tsnetState: Ipn.State?
    /// True after the backend explicitly confirms authentication but before it
    /// reaches Running. During this interval the backend can legitimately keep
    /// reporting NeedsLogin while control finishes registration/netmap work;
    /// presenting that as "Login Required" is misleading because no further
    /// user action is required.
    @Published var loggedInConnecting: Bool = false
    /// Changes whenever the system auth UI ends without `LoginFinished`, so
    /// Login buttons can stop their local tap-feedback spinner immediately.
    @Published var authSessionEndedGeneration: UInt64 = 0

    var authURL: String? = nil
    var observers: [AnyCancellable] = []
    var requestedInteractiveLogin = false

    let manager: TSNetManager

    let authManager = AuthManager()

    init(manager: TSNetManager) {
        self.manager = manager
        observeAuthURL()
    }

    private func observeAuthURL() {
        // NOTE: no `.removeDuplicates()` on `$state` here. The bus watcher
        // restarts every ~60s (no keep-alive on watch-ipn-bus) and re-emits
        // the current State via the initial-state dump; deduping State would
        // drop that re-emit, and if `browseToURL` wasn't also re-emitted in
        // the same dump the NeedsLogin+URL pairing could be missed — leaving
        // `authURL` stale/nil and Login silently broken. Re-evaluating on
        // every state emit is idempotent (the NeedsLogin branch just re-sets
        // authURL/needsAuth) and robust against the restart churn.
        manager.model.$state
            .combineLatest(manager.model.$browseToURL)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, browseToURL in
                guard let self else { return }

                if state == .NeedsLogin {
                    authURL = loggedInConnecting ? nil : browseToURL
                    needsAuth = !loggedInConnecting
                    if !loggedInConnecting, requestedInteractiveLogin, let browseToURL {
                        requestedInteractiveLogin = false
                        logger.log("observeAuthURL: fresh URL arrived while interactive login requested; opening sheet")
                        openAuthSession(browseToURL)
                    }
                } else {
                    // NOTE: do NOT reset `requestedInteractiveLogin` here.
                    // The user tapped Login (banner/gate) with no cached URL,
                    // so `showAuth` set the flag and called
                    // `startLoginInteractive()`; the fresh BrowseToURL arrives
                    // asynchronously on the bus. If the backend briefly flips
                    // the state to Starting/NoState before that URL lands, the
                    // old code reset the flag here — so when NeedsLogin+URL
                    // arrived a moment later the flag was false and the sheet
                    // NEVER opened (the "tap banner Login, nothing happens"
                    // device bug; the sim didn't flicker so the test passed).
                    // Leaving the flag sticky means the request survives the
                    // flicker and is consumed when the URL actually arrives;
                    // it only fires in the NeedsLogin+URL branch above, so a
                    // stale flag can't open a sheet at the wrong time.
                    needsAuth = false
                    authURL = nil
                    authManager.cancel(reason: "state changed to \(String(describing: state))")
                    // Drop any BrowseToURL the node emitted while logged in
                    // (tailscale can re-emit one right after `Running`). If we
                    // leave it, then after a logout — when the node returns to
                    // `NeedsLogin` WITHOUT emitting a fresh URL — the branch
                    // above would re-fill `authURL` from this STALE URL. The
                    // user's next Login would open the sheet with it: the OAuth
                    // completes on the control plane (the "Connect using the
                    // app" page even renders) but the node isn't watching for
                    // that callback, so the tailnet stays `NeedsLogin` and
                    // relogin silently fails. Clearing it here makes `authURL`
                    // nil after a logout, so `showAuth()` falls through to
                    // `startLoginInteractive()` and gets a fresh, watched URL.
                    if manager.model.browseToURL != nil {
                        manager.model.browseToURL = nil
                    }
                }

                running = state == .Running
                tsnetState = state
                if state == .Running {
                    loggedInConnecting = false
                }
            }
            .store(in: &observers)

        // `LoginFinished` is the backend's explicit signal that interactive
        // authentication succeeded. Dismiss on it immediately, as the regular
        // Tailscale app does, instead of keeping the separate auth window open
        // until the engine eventually reaches Starting/Running.
        manager.model.$loginFinishedGeneration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] generation in
                guard let self else { return }
                logger.log("StatusViewModel: handling LoginFinished generation \(generation)")
                requestedInteractiveLogin = false
                loggedInConnecting = true
                needsAuth = false
                authURL = nil
                authManager.authenticationSucceeded()
                if manager.model.browseToURL != nil {
                    manager.model.browseToURL = nil
                }
            }
            .store(in: &observers)

        Publishers.CombineLatest3(
            manager.model.$tailnetName,
            manager.model.$state,
            $loggedInConnecting
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name, state, loggedInConnecting in
                guard let self else { return }
                updateStatusText(state, name: name, loggedInConnecting: loggedInConnecting)
            }.store(in: &observers)
    }

    private func updateStatusText(_ state: Ipn.State?, name: String?, loggedInConnecting: Bool) {
        let mapping = mapState(state, name, loggedInConnecting: loggedInConnecting)
        statusText = mapping.text
        statusIconName = mapping.icon
    }

    private func mapState(_ state: Ipn.State?, _ name: String?, loggedInConnecting: Bool) -> (text: String, icon: String) {
        if loggedInConnecting && state != .Running {
            return ("Logged in. Connecting…", "arrow.trianglehead.2.clockwise.rotate.90.icloud")
        }
        switch state {
        case .some(.Running):
            return ("Connected\n\(name ?? "--")", "checkmark.circle.fill")
        case .some(.NeedsLogin):
            return ("Login Required", "person.crop.circle.badge.exclamationmark")
        case .some(.Stopped):
            return ("Stopped", "stop.circle.fill")
        case .some(.Starting):
            return ("Starting…", "hourglass.circle.fill")
        case .some(.NoState):
            fallthrough
        case .none:
            return ("Connecting…", "arrow.trianglehead.2.clockwise.rotate.90.icloud")
        default:
            // Fallback for any other states not explicitly handled
            return ("Working…", "ellipsis.circle")
        }
    }

    private func openAuthSession(_ url: String) {
        authManager.showAuth(authURL: url) { [weak self] in
            guard let self, needsAuth else { return }
            // A user-close/cancel is not a login request. Clear the pending
            // flag so a later unsolicited BrowseToURL cannot reopen the sheet,
            // and let StatusView's loading state follow this signal instead of
            // spinning for its two-minute safety timeout.
            requestedInteractiveLogin = false
            authSessionEndedGeneration &+= 1
        }
    }

    func showAuth() {
        if let authURL {
            logger.log("showAuth: opening auth sheet with cached URL: \(authURL)")
            openAuthSession(authURL)
        } else {
            // No URL yet — request a fresh interactive login and open the
            // sheet when the bus delivers the URL (observeAuthURL).
            logger.log("showAuth: no authURL yet; requesting interactive login")
            requestedInteractiveLogin = true
            Task {
                do {
                    try await manager.localAPIClient?.startLoginInteractive()
                } catch {
                    // Previously this was `try await` in an unawaited Task —
                    // a throw (e.g. localAPI not ready, node mid-restart) was
                    // silently dropped and no URL ever arrived, so the sheet
                    // never opened and the banner Login looked dead. Log it so
                    // it's diagnosable, and clear the flag so a later stale
                    // URL doesn't pop a sheet the user didn't expect.
                    logger.log("showAuth: startLoginInteractive failed: \(error)")
                    requestedInteractiveLogin = false
                }
            }
        }
    }

    func logout() {
        Task {
            do {
                let currentUser = try await manager.localAPIClient?.currentProfile()
                if let currentUser {
                    try await manager.localAPIClient?.deleteProfile(profileID: currentUser.id)
                    logger.log("Logout: deleted profile \(currentUser.id)")
                } else {
                    logger.log("Logout: no current profile; nothing to delete")
                }
            } catch {
                logger.log("Logout failed: \(error)")
            }
        }
    }
}
