import Foundation
import WatchConnectivity

/// Sends the refresh token to the watch. SPEC.md §9.1 step 2.
///
/// `transferUserInfo` and not `updateApplicationContext`: the latter is lossy
/// and last-write-wins, and dropping a rotated refresh token means the watch
/// is locked out until the owner notices and re-onboards.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    enum TransferError: LocalizedError {
        case unsupported
        case notPaired
        case watchAppNotInstalled

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "This device does not support Watch Connectivity."
            case .notPaired:
                "No Apple Watch is paired with this phone."
            case .watchAppNotInstalled:
                "Install the bio-rhythm watch app from the Watch app first."
            }
        }
    }

    /// Key for the transferred dictionary. The watch side must agree.
    static let refreshTokenKey = "refreshToken"

    @Published private(set) var pendingTransfers = 0
    @Published private(set) var lastError: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(refreshToken: String) throws {
        guard WCSession.isSupported() else { throw TransferError.unsupported }
        let session = WCSession.default
        guard session.isPaired else { throw TransferError.notPaired }
        guard session.isWatchAppInstalled else { throw TransferError.watchAppNotInstalled }

        // Queued by the system and retried until it lands, which is the whole
        // reason for choosing this over application context.
        session.transferUserInfo([Self.refreshTokenKey: refreshToken])
        pendingTransfers = session.outstandingUserInfoTransfers.count
    }
}

extension WatchLink: WCSessionDelegate {
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

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        let message = error?.localizedDescription
        let remaining = session.outstandingUserInfoTransfers.count
        Task { @MainActor in
            self.lastError = message
            self.pendingTransfers = remaining
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a watch swap does not silently stop delivering.
        WCSession.default.activate()
    }
}
