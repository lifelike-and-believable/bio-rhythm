/// The payload contract for the one message this product sends between
/// devices: the refresh token, phone to watch, once, at onboarding.
/// SPEC.md §9.1 step 2.
///
/// Shared by both app targets deliberately. The two sides have to agree on the
/// key, and if they ever drift the failure is silent — `transferUserInfo`
/// delivers, the watch reads a key that isn't there, and onboarding simply
/// never completes with nothing to show for it.
///
/// Deliberately not isolated to an actor: the watch reads it from the
/// `nonisolated` `WCSessionDelegate` callback, which is where the transfer
/// arrives.
enum WatchTransfer {
    static let refreshTokenKey = "refreshToken"
}
