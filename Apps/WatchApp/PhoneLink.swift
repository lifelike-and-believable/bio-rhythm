import Foundation
import WatchConnectivity
import SpotifyKit

/// Receives the refresh token from the phone and puts it in the Keychain.
/// SPEC.md §9.1 step 3.
///
/// This runs exactly once per onboarding. Nothing during a workout depends on
/// the phone being reachable (G3, R-5).
@MainActor
final class PhoneLink: NSObject, ObservableObject {
    static let refreshTokenKey = "refreshToken"

    @Published private(set) var hasToken = false
    @Published private(set) var lastError: String?

    private let store: any TokenStore

    init(store: any TokenStore) {
        self.store = store
        super.init()
        refreshTokenPresence()

        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refreshTokenPresence() {
        do {
            hasToken = try store.loadRefreshToken() != nil
        } catch {
            hasToken = false
            lastError = error.localizedDescription
        }
    }

    fileprivate func accept(refreshToken: String) {
        do {
            try store.save(refreshToken: refreshToken)
            hasToken = true
            lastError = nil
        } catch {
            lastError = "Could not save to Keychain: \(error.localizedDescription)"
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: (any Error)?
    ) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.lastError = message
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let token = userInfo[Self.refreshTokenKey] as? String else { return }
        Task { @MainActor in
            self.accept(refreshToken: token)
        }
    }
}
