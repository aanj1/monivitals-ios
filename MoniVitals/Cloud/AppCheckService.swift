//
//  AppCheckService.swift
//  MoniVitals
//
//  Firebase App Check over the raw REST API — plain URLSession, no Firebase
//  SDK, same as AuthService/SyncService. Real devices attest with App Attest
//  (DeviceCheck); Debug builds (and the simulator, where App Attest is not
//  supported) fall back to a debug token injected from
//  Config/AppCheckDebug.xcconfig into Info.plist — never hardcoded here.
//
//  App Check runs in MONITOR mode server-side (unenforced), so every failure
//  here degrades to "no header": `currentToken()` answers nil and the caller
//  sends the request without `X-Firebase-AppCheck`. A missing token must
//  never block sync.
//

import CryptoKit
import DeviceCheck
import Foundation
import os

// MARK: - Token model (pure, unit-tested)

/// A minted App Check token plus its absolute expiry (epoch seconds),
/// persisted as one Keychain blob like `AuthState`.
struct AppCheckToken: Codable, Equatable {
    var token: String
    var expiresAt: TimeInterval

    /// Usable while more than the leeway remains (mirrors AuthService's
    /// proactive 5-minute refresh window).
    func isUsable(now: Date = Date(),
                  leeway: TimeInterval = AppCheckService.refreshLeewaySeconds) -> Bool {
        expiresAt - now.timeIntervalSince1970 > leeway
    }
}

// MARK: - App Check service

/// Serializes token minting behind one actor so concurrent cloud calls share a
/// single fetch instead of racing attestations.
actor AppCheckService {
    static let shared = AppCheckService()

    /// Refresh proactively when the token has less than this long left (spec: 5 min).
    static let refreshLeewaySeconds: TimeInterval = 5 * 60

    /// After a failed mint, skip retries this long so one sync pass (many
    /// requests) doesn't re-attempt an exchange per request.
    static let failureCooldownSeconds: TimeInterval = 60

    /// Firebase iOS app id (mirrors GOOGLE_APP_ID in GoogleService-Info.plist).
    static let appId = "1:981916297971:ios:2deff47b76f2f887d4e586"

    private static let base =
        "https://firebaseappcheck.googleapis.com/v1/projects/monivitals/apps/\(appId)"

    /// Info.plist key fed from APP_CHECK_DEBUG_TOKEN (Config/AppCheckDebug.xcconfig,
    /// Debug builds only — Release expands it to an empty string).
    static let debugTokenInfoKey = "AppCheckDebugToken"

    // Keychain accounts (KeychainStore, same service as the auth blob).
    private static let tokenAccount = "appcheck-token"
    private static let keyIdAccount = "appcheck-keyid"
    private static let artifactAccount = "appcheck-artifact"

    /// Failure diagnostics only — never the token, debug token, or key material.
    private let log = Logger(subsystem: "com.monivitals.app", category: "AppCheck")

    private var cached: AppCheckToken?
    private var loadedPersisted = false
    private var inflight: Task<AppCheckToken?, Never>?
    private var lastFailureAt: TimeInterval = 0

    init() {}

    // MARK: Public entry point

    /// The current App Check token, minting/refreshing as needed. Nil means
    /// "send the request without the header" — never an error to surface.
    func currentToken() async -> String? {
        if !loadedPersisted {
            loadedPersisted = true
            cached = KeychainStore.load(AppCheckToken.self, account: Self.tokenAccount)
        }
        let now = Date()
        if let cached, cached.isUsable(now: now) { return cached.token }
        if let minted = await mintDeduped(now: now) { return minted.token }
        // Best effort: a token inside the leeway but not yet expired still
        // beats no header at all while the refresh keeps failing.
        if let cached, cached.expiresAt > now.timeIntervalSince1970 { return cached.token }
        return nil
    }

    // MARK: Minting (deduped + cooldown)

    private func mintDeduped(now: Date) async -> AppCheckToken? {
        if let inflight { return await inflight.value }
        if now.timeIntervalSince1970 - lastFailureAt < Self.failureCooldownSeconds {
            return nil
        }
        let task = Task { await mint() }
        inflight = task
        let token = await task.value
        inflight = nil
        if let token {
            cached = token
            KeychainStore.save(token, account: Self.tokenAccount)
        } else {
            lastFailureAt = Date().timeIntervalSince1970
        }
        return token
    }

    /// Primary path: App Attest on real hardware. Fallback: debug-token
    /// exchange in Debug builds (simulator has no App Attest). Anything else
    /// answers nil — App Check is unenforced server-side.
    private func mint() async -> AppCheckToken? {
        guard let apiKey = AuthService.apiKey() else { return nil }
        if DCAppAttestService.shared.isSupported,
           let token = await appAttestToken(apiKey: apiKey) {
            return token
        }
        #if DEBUG
        return await exchangeDebugToken(apiKey: apiKey)
        #else
        return nil
        #endif
    }

    // MARK: App Attest flow (real devices)

    private func appAttestToken(apiKey: String) async -> AppCheckToken? {
        let service = DCAppAttestService.shared
        // Later runs: assert with the attested key + stored artifact.
        if let keyId = KeychainStore.load(String.self, account: Self.keyIdAccount),
           let artifact = KeychainStore.load(String.self, account: Self.artifactAccount) {
            switch await exchangeAssertion(service: service, keyId: keyId,
                                           artifact: artifact, apiKey: apiKey) {
            case .token(let token):
                return token
            case .rejected:
                // The server no longer accepts this key/artifact — start over.
                log.debug("App Attest assertion rejected — re-attesting")
                KeychainStore.delete(account: Self.keyIdAccount)
                KeychainStore.delete(account: Self.artifactAccount)
            case .unavailable:
                return nil // likely offline — keep the attested key for later
            }
        }
        // First run (or after a rejection): fresh attestation.
        return await exchangeAttestation(service: service, apiKey: apiKey)
    }

    private enum AssertOutcome {
        case token(AppCheckToken)
        /// The server (or Secure Enclave) refused the key/artifact — re-attest.
        case rejected
        /// Transport trouble — try again later without burning the key.
        case unavailable
    }

    private func exchangeAssertion(service: DCAppAttestService, keyId: String,
                                   artifact: String, apiKey: String) async -> AssertOutcome {
        guard let url = Self.endpoint("exchangeAppAttestAssertion", apiKey: apiKey),
              let challenge = await fetchChallenge(apiKey: apiKey) else { return .unavailable }
        let hash = Data(SHA256.hash(data: challenge))
        let assertion: Data
        do {
            assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
        } catch {
            return .rejected // key vanished or is invalid → re-attest
        }
        let body: [String: Any] = [
            "artifact": artifact,
            "assertion": assertion.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
        ]
        switch await postJSON(url, body: body) {
        case .success(let data):
            guard let token = Self.parseTokenResponse(data) else { return .unavailable }
            return .token(token)
        case .rejected:
            return .rejected
        case .unreachable:
            return .unavailable
        }
    }

    private func exchangeAttestation(service: DCAppAttestService,
                                     apiKey: String) async -> AppCheckToken? {
        guard let url = Self.endpoint("exchangeAppAttestAttestation", apiKey: apiKey),
              let challenge = await fetchChallenge(apiKey: apiKey) else { return nil }
        // Reuse a generated-but-never-attested key when a previous pass stalled
        // before the exchange; otherwise mint one and remember it.
        var keyId = KeychainStore.load(String.self, account: Self.keyIdAccount)
        if keyId == nil {
            keyId = try? await service.generateKey()
            if let keyId { KeychainStore.save(keyId, account: Self.keyIdAccount) }
        }
        guard let keyId else { return nil }
        let hash = Data(SHA256.hash(data: challenge))
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: hash)
        } catch {
            // The key may already be attested (artifact lost) or invalid —
            // drop it so the next pass starts clean with a fresh key.
            log.debug("App Attest attestKey failed — resetting key")
            KeychainStore.delete(account: Self.keyIdAccount)
            return nil
        }
        let body: [String: Any] = [
            "attestationStatement": attestation.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
            "keyId": Data(keyId.utf8).base64EncodedString(),
        ]
        switch await postJSON(url, body: body) {
        case .success(let data):
            guard let (artifact, token) = Self.parseAttestationResponse(data) else {
                return nil
            }
            KeychainStore.save(artifact, account: Self.artifactAccount)
            return token
        case .rejected:
            // An attestation is one-shot per key — a refused key can't retry.
            log.debug("App Attest attestation exchange rejected")
            KeychainStore.delete(account: Self.keyIdAccount)
            return nil
        case .unreachable:
            return nil
        }
    }

    private func fetchChallenge(apiKey: String) async -> Data? {
        guard let url = Self.endpoint("generateAppAttestChallenge", apiKey: apiKey),
              case .success(let data) = await postJSON(url, body: [:]) else { return nil }
        return Self.parseChallenge(data)
    }

    // MARK: Debug token flow (Debug builds / simulator)

    #if DEBUG
    private func exchangeDebugToken(apiKey: String) async -> AppCheckToken? {
        guard let debugToken = Self.debugToken(),
              let url = Self.endpoint("exchangeDebugToken", apiKey: apiKey),
              case .success(let data) = await postJSON(url, body: ["debugToken": debugToken])
        else {
            log.debug("App Check debug-token exchange unavailable")
            return nil
        }
        return Self.parseTokenResponse(data)
    }
    #endif

    /// The debug token injected into Info.plist from Config/AppCheckDebug.xcconfig.
    static func debugToken(bundle: Bundle = .main) -> String? {
        normalizedDebugToken(bundle.object(forInfoDictionaryKey: debugTokenInfoKey) as? String)
    }

    /// Filter out empty and unexpanded `$(…)` placeholder values (pure,
    /// unit-tested) — Release builds carry an empty string under the key.
    static func normalizedDebugToken(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("$(") else { return nil }
        return raw
    }

    // MARK: Response parsing (pure, unit-tested)

    /// Parse `{"token"|"attestationToken": "...", "ttl": "3600s"}` — flat (v1
    /// exchange responses) or nested under `appCheckToken`/`attestationToken`
    /// (v1/v1beta attestation responses). Anything else → nil.
    static func parseTokenResponse(_ data: Data, now: Date = Date()) -> AppCheckToken? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parseToken(obj, now: now)
    }

    private static func parseToken(_ obj: [String: Any], now: Date) -> AppCheckToken? {
        if let nested = (obj["appCheckToken"] ?? obj["attestationToken"]) as? [String: Any] {
            return parseToken(nested, now: now)
        }
        guard let token = (obj["token"] ?? obj["attestationToken"]) as? String,
              !token.isEmpty else { return nil }
        let lifetime = ttlSeconds(obj["ttl"] as? String) ?? 3600
        return AppCheckToken(token: token,
                             expiresAt: now.timeIntervalSince1970 + lifetime)
    }

    /// Parse an `exchangeAppAttestAttestation` response: the artifact to keep
    /// for later assertions plus the freshly minted token.
    static func parseAttestationResponse(
        _ data: Data, now: Date = Date()
    ) -> (artifact: String, token: AppCheckToken)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let artifact = obj["artifact"] as? String, !artifact.isEmpty,
              let token = parseToken(obj, now: now) else { return nil }
        return (artifact, token)
    }

    /// Parse a `generateAppAttestChallenge` response into raw challenge bytes.
    static func parseChallenge(_ data: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let challenge = obj["challenge"] as? String else { return nil }
        return Data(base64Encoded: challenge)
    }

    /// `"3600s"` → 3600. Unknown shapes → nil (caller falls back to one hour).
    static func ttlSeconds(_ ttl: String?) -> TimeInterval? {
        guard let ttl, ttl.hasSuffix("s"),
              let seconds = TimeInterval(ttl.dropLast()), seconds > 0 else { return nil }
        return seconds
    }

    // MARK: Plumbing

    private static func endpoint(_ action: String, apiKey: String) -> URL? {
        URL(string: "\(base):\(action)?key=\(apiKey)")
    }

    private enum PostResult {
        case success(Data)
        /// HTTP 4xx — the server refused what we sent.
        case rejected
        /// Transport error or 5xx — worth trying again later.
        case unreachable
    }

    private func postJSON(_ url: URL, body: [String: Any]) async -> PostResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The API key is application-restricted to this bundle id; the mint
        // endpoints check the same header as every other Google REST call.
        if let bundleId = Bundle.main.bundleIdentifier {
            req.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        if (200..<300).contains(http.statusCode) { return .success(data) }
        log.debug("App Check exchange answered HTTP \(http.statusCode)")
        return (400..<500).contains(http.statusCode) ? .rejected : .unreachable
    }
}

// MARK: - Request decoration (the one touchpoint for the header)

extension URLRequest {
    /// Attach `X-Firebase-AppCheck` when a token is available. App Check is
    /// in monitor mode server-side, so nil means "send without the header" —
    /// it never blocks or fails the request.
    ///
    /// Also stamps `X-Ios-Bundle-Identifier`: the Google API key is
    /// application-restricted to this bundle id, and REST callers must
    /// identify themselves via this header for the restriction check.
    mutating func attachAppCheck() async {
        if let bundleId = Bundle.main.bundleIdentifier {
            setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        if let token = await AppCheckService.shared.currentToken() {
            setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
    }
}
