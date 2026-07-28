import Foundation

/// Authorization Code with PKCE. SPEC.md §9.1 — no client secret on device.
public struct PKCEPair: Sendable {
    /// Kept by the client, sent with the code exchange.
    public let verifier: String
    /// Sent with the authorization request.
    public let challenge: String
    public let method = "S256"
}

public enum PKCE {
    /// 43–128 characters of unreserved ASCII, per RFC 7636. 64 random bytes
    /// base64url-encode to 86 characters, comfortably inside that range.
    public static func generateVerifier(byteCount: Int = 64) -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return base64URLEncode(Data(bytes))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if canImport(CryptoKit)
import CryptoKit

extension PKCE {
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    public static func generate() -> PKCEPair {
        let verifier = generateVerifier()
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }
}
#endif
