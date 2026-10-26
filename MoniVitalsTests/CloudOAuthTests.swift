//
//  CloudOAuthTests.swift
//  MoniVitalsTests
//
//  Pure-function coverage for federated sign-in (docs/CLOUD_OAUTH.md): PKCE
//  challenge derivation, Apple nonce hashing, the signInWithIdp postBody builder
//  (Google vs Apple, nonce present/absent), Google OAuth URL/body builders, and the
//  new friendly-error mappings. No network or UI is exercised.
//

import CryptoKit
import XCTest
@testable import MoniVitals

final class CloudOAuthTests: XCTestCase {

    // MARK: - PKCE (RFC 7636)

    /// RFC 7636 Appendix B worked example: a known verifier → known challenge.
    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCE.challenge(for: verifier), expected)
    }

    func testPKCEChallengeIsBase64URLNoPadding() {
        let challenge = PKCE.challenge(for: PKCE.makeVerifier())
        XCTAssertFalse(challenge.contains("+"), "must be url-safe")
        XCTAssertFalse(challenge.contains("/"), "must be url-safe")
        XCTAssertFalse(challenge.contains("="), "must be unpadded")
    }

    func testPKCEVerifierLengthAndCharset() {
        let allowed = Set(PKCE.verifierAllowed)
        for len in [10, 43, 64, 128, 999] {
            let v = PKCE.makeVerifier(length: len)
            // Clamped to the RFC 7636 43…128 range.
            XCTAssertGreaterThanOrEqual(v.count, 43)
            XCTAssertLessThanOrEqual(v.count, 128)
            XCTAssertTrue(v.allSatisfy { allowed.contains($0) },
                          "verifier must be drawn from the unreserved set")
        }
    }

    func testPKCEBase64URLNoPaddingKnownBytes() {
        // SHA256("") = e3b0c442... — its base64url form (unpadded).
        let digest = SHA256.hash(data: Data("".utf8))
        XCTAssertEqual(PKCE.base64URLNoPadding(Data(digest)),
                       "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    // MARK: - Apple nonce

    func testAppleNonceSHA256HexRoundTrip() {
        let raw = "abc123"
        // Independently computed SHA-256 of "abc123".
        let expected = "6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090"
        XCTAssertEqual(AppleNonce.sha256Hex(raw), expected)
    }

    func testAppleNonceSHA256IsLowercaseHex64() {
        let hex = AppleNonce.sha256Hex(AppleNonce.makeRaw())
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testAppleNonceRawLengthAndCharset() {
        let allowed = Set(AppleNonce.allowed)
        let raw = AppleNonce.makeRaw(length: 32)
        XCTAssertEqual(raw.count, 32)
        XCTAssertTrue(raw.allSatisfy { allowed.contains($0) })
    }

    func testAppleNonceSHA256Deterministic() {
        XCTAssertEqual(AppleNonce.sha256Hex("same"), AppleNonce.sha256Hex("same"))
    }

    // MARK: - signInWithIdp postBody builder

    func testIdpPostBodyGoogleHasNoNonce() {
        let body = AuthService.signInWithIdpPostBody(
            idToken: "GTOKEN", providerId: "google.com", rawNonce: nil)
        XCTAssertEqual(body, "id_token=GTOKEN&providerId=google.com")
        XCTAssertFalse(body.contains("nonce"))
    }

    func testIdpPostBodyGoogleEmptyNonceOmitted() {
        let body = AuthService.signInWithIdpPostBody(
            idToken: "GTOKEN", providerId: "google.com", rawNonce: "")
        XCTAssertEqual(body, "id_token=GTOKEN&providerId=google.com")
    }

    func testIdpPostBodyAppleAppendsRawNonce() {
        let body = AuthService.signInWithIdpPostBody(
            idToken: "ATOKEN", providerId: "apple.com", rawNonce: "RAWNONCE")
        XCTAssertEqual(body, "id_token=ATOKEN&providerId=apple.com&nonce=RAWNONCE")
    }

    func testIdpPostBodyAppleWithoutNonce() {
        // Defensive: if apple ever came through without a nonce the builder still
        // produces a valid two-field body rather than a dangling "&nonce=".
        let body = AuthService.signInWithIdpPostBody(
            idToken: "ATOKEN", providerId: "apple.com", rawNonce: nil)
        XCTAssertEqual(body, "id_token=ATOKEN&providerId=apple.com")
    }

    func testIdpProviderRawValues() {
        XCTAssertEqual(AuthService.IdpProvider.google.rawValue, "google.com")
        XCTAssertEqual(AuthService.IdpProvider.apple.rawValue, "apple.com")
    }

    // MARK: - Google OAuth URL / body builders

    func testGoogleRedirectURI() {
        let reversed = "com.googleusercontent.apps.123-abc"
        XCTAssertEqual(GoogleOAuth.redirectURI(reversedClientId: reversed),
                       "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    func testGoogleAuthorizeURLCarriesPKCEAndScopes() throws {
        let url = try XCTUnwrap(GoogleOAuth.authorizeURL(
            clientId: "CID.apps.googleusercontent.com",
            reversedClientId: "com.googleusercontent.apps.CID",
            codeChallenge: "CHALLENGE"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(comps.host, "accounts.google.com")
        XCTAssertEqual(items["client_id"], "CID.apps.googleusercontent.com")
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.CID:/oauth2redirect")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid email profile")
        XCTAssertEqual(items["code_challenge"], "CHALLENGE")
        XCTAssertEqual(items["code_challenge_method"], "S256")
    }

    func testGoogleCodeParsedFromCallback() throws {
        let cb = try XCTUnwrap(URL(string:
            "com.googleusercontent.apps.CID:/oauth2redirect?code=AUTHCODE&scope=openid"))
        XCTAssertEqual(GoogleOAuth.code(from: cb), "AUTHCODE")
    }

    func testGoogleCodeMissingReturnsNil() throws {
        let cb = try XCTUnwrap(URL(string:
            "com.googleusercontent.apps.CID:/oauth2redirect?error=access_denied"))
        XCTAssertNil(GoogleOAuth.code(from: cb))
    }

    func testGoogleTokenExchangeBody() {
        let body = GoogleOAuth.tokenExchangeBody(
            code: "AUTHCODE", clientId: "CID",
            reversedClientId: "com.googleusercontent.apps.CID", codeVerifier: "VERIFIER")
        XCTAssertTrue(body.contains("code=AUTHCODE"))
        XCTAssertTrue(body.contains("client_id=CID"))
        XCTAssertTrue(body.contains("code_verifier=VERIFIER"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        // ':' and '/' in the redirect uri must be percent-escaped.
        XCTAssertTrue(body.contains("redirect_uri=com.googleusercontent.apps.CID%3A%2Foauth2redirect"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    // MARK: - Friendly error mapping (federated additions)

    func testFriendlyMessageFederatedAlreadyLinked() {
        XCTAssertEqual(
            AuthService.friendlyAuthMessage("FEDERATED_USER_ID_ALREADY_LINKED"),
            "That email is already signed up a different way — try that instead.")
    }

    func testFriendlyMessageFederatedAlreadyLinkedWithSuffix() {
        XCTAssertEqual(
            AuthService.friendlyAuthMessage("FEDERATED_USER_ID_ALREADY_LINKED : extra detail"),
            "That email is already signed up a different way — try that instead.")
    }

    func testFriendlyMessageMissingOrInvalidNonce() {
        XCTAssertEqual(
            AuthService.friendlyAuthMessage("MISSING_OR_INVALID_NONCE"),
            "Couldn't finish signing you in — please try again.")
    }

    /// EMAIL_EXISTS keeps its existing password-path copy (it can only map one way);
    /// the federated case is covered by FEDERATED_USER_ID_ALREADY_LINKED above.
    func testEmailExistsCopyUnchanged() {
        XCTAssertEqual(AuthService.friendlyAuthMessage("EMAIL_EXISTS"),
                       "That email already has an account — try signing in instead.")
    }
}
