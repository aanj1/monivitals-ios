//
//  AppleSignIn.swift
//  MoniVitals
//
//  Native "Sign in with Apple" via AuthenticationServices. A RAW nonce is generated
//  and its SHA-256 hash is attached to the authorization request; Apple embeds that
//  hash in the returned JWT. We hand the JWT plus the RAW nonce to
//  AuthService.completeIdpSignIn, which forwards both to Identity Toolkit
//  `accounts:signInWithIdp` (providerId `apple.com`) — Firebase re-hashes the raw
//  nonce and compares (docs/CLOUD_OAUTH.md).
//
//  The nonce helpers are pure static funcs so they unit-test without any UI. The
//  ASAuthorizationController delegate is the only interactive part.
//
//  Native Apple sign-in uses the app's bundle id as its audience — no Service ID is
//  needed on iOS. The entitlement (MoniVitals.entitlements) must be present.
//

import AuthenticationServices
import CryptoKit
import Foundation

// MARK: - Nonce helpers (pure, unit-tested)

/// Nonce plumbing for Sign in with Apple. The RAW nonce travels to Firebase in the
/// signInWithIdp postBody; only its SHA-256 hash is put on the Apple request.
enum AppleNonce {
    /// The unreserved characters a nonce is drawn from.
    static let allowed = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    /// Generate a cryptographically-random RAW nonce string.
    static func makeRaw(length: Int = 32) -> String {
        var out = ""
        out.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if Int(random) < allowed.count {
                out.append(allowed[Int(random)])
                remaining -= 1
            }
        }
        return out
    }

    /// Lowercase hex SHA-256 of the raw nonce — this is what goes on the Apple
    /// request (`request.nonce`) and what Apple stamps into the JWT `nonce` claim.
    static func sha256Hex(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Interactive Apple sign-in

/// Drives the native Apple authorization flow and returns the Firebase AuthState.
/// A user cancel throws `AppleSignIn.Cancelled`, which callers treat as silent.
@MainActor
final class AppleSignIn: NSObject {

    /// Thrown when the user cancels the native sheet — surfaced as no error UI.
    struct Cancelled: Error {}

    private var continuation: CheckedContinuation<AuthState, Error>?
    private var rawNonce: String = ""
    /// Keeps the in-flight controller alive until a delegate callback fires —
    /// ASAuthorizationController is not retained by the system, and letting it
    /// deallocate would leave the continuation hanging forever.
    private var controller: ASAuthorizationController?

    /// Present the native Sign in with Apple sheet and complete the exchange.
    func signIn() async throws -> AuthState {
        let raw = AppleNonce.makeRaw()
        rawNonce = raw

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleNonce.sha256Hex(raw)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    /// Compose a friendly display email from the returned credential — Apple only
    /// sends the name/email on the first sign-in, so this may be nil later.
    static func displayEmail(from credential: ASAuthorizationAppleIDCredential) -> String? {
        if let email = credential.email, !email.isEmpty { return email }
        return nil
    }

    /// Complete sign-in from a credential the SwiftUI `SignInWithAppleButton`
    /// already collected. The button sets the request nonce (its SHA-256 hash) in
    /// its `onRequest`; the matching RAW nonce is threaded back here so Firebase can
    /// re-hash and compare. Keeps nonce + token-exchange logic in one place while
    /// the UI uses the standard themed button (docs/CLOUD_OAUTH.md).
    static func complete(with credential: ASAuthorizationAppleIDCredential,
                         rawNonce: String) async throws -> AuthState {
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        return try await AuthService.completeIdpSignIn(
            idToken: idToken, providerId: .apple,
            rawNonce: rawNonce, fallbackEmail: displayEmail(from: credential))
    }
}

// MARK: - Delegate

extension AppleSignIn: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithAuthorization authorization: ASAuthorization) {
        self.controller = nil
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: CloudError.friendly(AuthService.offlineMessage))
            continuation = nil
            return
        }
        let fallbackEmail = Self.displayEmail(from: credential)
        let raw = rawNonce
        let cont = continuation
        continuation = nil
        Task {
            do {
                let state = try await AuthService.completeIdpSignIn(
                    idToken: idToken, providerId: .apple,
                    rawNonce: raw, fallbackEmail: fallbackEmail)
                cont?.resume(returning: state)
            } catch {
                cont?.resume(throwing: error)
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithError error: Error) {
        self.controller = nil
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            continuation?.resume(throwing: Cancelled())
        } else {
            continuation?.resume(throwing: CloudError.friendly(AuthService.offlineMessage))
        }
        continuation = nil
    }
}

// MARK: - Presentation context

extension AppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
