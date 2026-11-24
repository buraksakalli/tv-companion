import CryptoKit
import Foundation
import Security

/// The TV serves a self-signed certificate, so normal CA validation can't work.
/// Instead of disabling TLS checks, we pin the leaf certificate on first successful
/// pairing (trust-on-first-use) and reject any other certificate afterwards.
final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinnedFingerprint: String?
    private let lock = NSLock()
    private var _observed: String?

    /// SHA-256 of the leaf certificate presented during the last handshake.
    var observedFingerprint: String? { lock.withLock { _observed } }

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { return (.cancelAuthenticationChallenge, nil) }

        let fingerprint = Self.fingerprint(of: SecCertificateCopyData(leaf) as Data)
        lock.withLock { _observed = fingerprint }

        if let pinnedFingerprint, pinnedFingerprint != fingerprint {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
