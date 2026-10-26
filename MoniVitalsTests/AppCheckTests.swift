//
//  AppCheckTests.swift
//  MoniVitalsTests
//
//  Pure-function coverage for the App Check layer: ttl/response parsing across
//  the v1 and v1beta shapes, challenge decoding, token expiry math, and the
//  debug-token normalization that keeps Release builds token-free. No network
//  or DeviceCheck hardware is exercised — the graceful-nil paths are all pure.
//

import XCTest
@testable import MoniVitals

final class AppCheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - ttl parsing

    func testTTLParsesWholeAndFractionalSeconds() {
        XCTAssertEqual(AppCheckService.ttlSeconds("3600s"), 3600)
        XCTAssertEqual(AppCheckService.ttlSeconds("60s"), 60)
        XCTAssertEqual(AppCheckService.ttlSeconds("1800.5s"), 1800.5)
    }

    func testTTLRejectsGarbage() {
        XCTAssertNil(AppCheckService.ttlSeconds(nil))
        XCTAssertNil(AppCheckService.ttlSeconds(""))
        XCTAssertNil(AppCheckService.ttlSeconds("3600"))
        XCTAssertNil(AppCheckService.ttlSeconds("s"))
        XCTAssertNil(AppCheckService.ttlSeconds("soons"))
        XCTAssertNil(AppCheckService.ttlSeconds("-60s"))
        XCTAssertNil(AppCheckService.ttlSeconds("0s"))
    }

    // MARK: - token response parsing (v1 flat, v1beta flat, nested)

    func testParseV1FlatTokenResponse() {
        let data = Data(#"{"token": "tok-abc", "ttl": "3600s"}"#.utf8)
        let token = AppCheckService.parseTokenResponse(data, now: now)
        XCTAssertEqual(token?.token, "tok-abc")
        XCTAssertEqual(token?.expiresAt, now.timeIntervalSince1970 + 3600)
    }

    func testParseV1BetaFlatAttestationTokenResponse() {
        let data = Data(#"{"attestationToken": "tok-beta", "ttl": "1800s"}"#.utf8)
        let token = AppCheckService.parseTokenResponse(data, now: now)
        XCTAssertEqual(token?.token, "tok-beta")
        XCTAssertEqual(token?.expiresAt, now.timeIntervalSince1970 + 1800)
    }

    func testParseNestedAppCheckTokenResponse() {
        let data = Data(#"{"appCheckToken": {"token": "tok-nested", "ttl": "60s"}}"#.utf8)
        let token = AppCheckService.parseTokenResponse(data, now: now)
        XCTAssertEqual(token?.token, "tok-nested")
        XCTAssertEqual(token?.expiresAt, now.timeIntervalSince1970 + 60)
    }

    func testParseNestedV1BetaAttestationTokenResponse() {
        let data = Data(
            #"{"attestationToken": {"attestationToken": "tok-bn", "ttl": "60s"}}"#.utf8)
        XCTAssertEqual(AppCheckService.parseTokenResponse(data, now: now)?.token, "tok-bn")
    }

    func testParseTokenMissingTTLFallsBackToOneHour() {
        let data = Data(#"{"token": "tok-nottl"}"#.utf8)
        let token = AppCheckService.parseTokenResponse(data, now: now)
        XCTAssertEqual(token?.token, "tok-nottl")
        XCTAssertEqual(token?.expiresAt, now.timeIntervalSince1970 + 3600)
    }

    func testParseTokenGracefulNilOnGarbage() {
        XCTAssertNil(AppCheckService.parseTokenResponse(Data(), now: now))
        XCTAssertNil(AppCheckService.parseTokenResponse(Data("not json".utf8), now: now))
        XCTAssertNil(AppCheckService.parseTokenResponse(Data("[]".utf8), now: now))
        XCTAssertNil(AppCheckService.parseTokenResponse(Data("{}".utf8), now: now))
        XCTAssertNil(AppCheckService.parseTokenResponse(
            Data(#"{"token": "", "ttl": "3600s"}"#.utf8), now: now))
        XCTAssertNil(AppCheckService.parseTokenResponse(
            Data(#"{"error": {"message": "PERMISSION_DENIED"}}"#.utf8), now: now))
    }

    // MARK: - attestation response parsing (artifact + token)

    func testParseAttestationResponseYieldsArtifactAndToken() {
        let data = Data(
            #"{"artifact": "art-b64", "appCheckToken": {"token": "tok-a", "ttl": "3600s"}}"#.utf8)
        let parsed = AppCheckService.parseAttestationResponse(data, now: now)
        XCTAssertEqual(parsed?.artifact, "art-b64")
        XCTAssertEqual(parsed?.token.token, "tok-a")
        XCTAssertEqual(parsed?.token.expiresAt, now.timeIntervalSince1970 + 3600)
    }

    func testParseAttestationResponseGracefulNilWithoutArtifactOrToken() {
        XCTAssertNil(AppCheckService.parseAttestationResponse(
            Data(#"{"appCheckToken": {"token": "tok", "ttl": "3600s"}}"#.utf8), now: now))
        XCTAssertNil(AppCheckService.parseAttestationResponse(
            Data(#"{"artifact": "art-b64"}"#.utf8), now: now))
        XCTAssertNil(AppCheckService.parseAttestationResponse(Data("{}".utf8), now: now))
    }

    // MARK: - challenge parsing

    func testParseChallengeDecodesBase64() {
        let raw = Data("challenge-bytes".utf8)
        let json = Data(#"{"challenge": "\#(raw.base64EncodedString())", "ttl": "60s"}"#.utf8)
        XCTAssertEqual(AppCheckService.parseChallenge(json), raw)
    }

    func testParseChallengeGracefulNil() {
        XCTAssertNil(AppCheckService.parseChallenge(Data("{}".utf8)))
        XCTAssertNil(AppCheckService.parseChallenge(
            Data(#"{"challenge": "not base64!!!"}"#.utf8)))
        XCTAssertNil(AppCheckService.parseChallenge(Data("garbage".utf8)))
    }

    // MARK: - cache expiry math

    func testTokenUsableWhileMoreThanLeewayRemains() {
        let token = AppCheckToken(token: "t",
                                  expiresAt: now.timeIntervalSince1970 + 3600)
        XCTAssertTrue(token.isUsable(now: now))
    }

    func testTokenNotUsableInsideFiveMinuteLeeway() {
        // 4 minutes left — inside the 5-minute refresh window, so refresh.
        let token = AppCheckToken(token: "t",
                                  expiresAt: now.timeIntervalSince1970 + 240)
        XCTAssertFalse(token.isUsable(now: now))
    }

    func testTokenNotUsableExactlyAtLeewayBoundary() {
        let token = AppCheckToken(
            token: "t",
            expiresAt: now.timeIntervalSince1970 + AppCheckService.refreshLeewaySeconds)
        XCTAssertFalse(token.isUsable(now: now))
    }

    func testExpiredTokenNotUsable() {
        let token = AppCheckToken(token: "t",
                                  expiresAt: now.timeIntervalSince1970 - 1)
        XCTAssertFalse(token.isUsable(now: now))
    }

    // MARK: - debug token normalization (Release must read as nil)

    func testNormalizedDebugTokenPassesRealValues() {
        XCTAssertEqual(AppCheckService.normalizedDebugToken("ABCD-1234"), "ABCD-1234")
        XCTAssertEqual(AppCheckService.normalizedDebugToken("  tok  "), "tok")
    }

    func testNormalizedDebugTokenRejectsEmptyAndPlaceholders() {
        XCTAssertNil(AppCheckService.normalizedDebugToken(nil))
        XCTAssertNil(AppCheckService.normalizedDebugToken(""))
        XCTAssertNil(AppCheckService.normalizedDebugToken("   "))
        // An unexpanded build setting must never be sent as a token.
        XCTAssertNil(AppCheckService.normalizedDebugToken("$(APP_CHECK_DEBUG_TOKEN)"))
    }

    func testDebugTokenAbsentFromBundleReadsAsNil() {
        // The test bundle has no AppCheckDebugToken key — graceful nil.
        XCTAssertNil(AppCheckService.debugToken(bundle: Bundle(for: Self.self)))
    }
}
