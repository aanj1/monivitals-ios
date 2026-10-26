//
//  AuthService.swift
//  MoniVitals
//
//  Optional email/password accounts against the Firebase Identity Toolkit REST
//  API (docs/CLOUD_SYNC.md) — plain URLSession, no Firebase SDK. The app stays
//  fully usable signed out; an account only adds cloud backup.
//
//  The API key is read at runtime from the bundled GoogleService-Info.plist,
//  never hardcoded here. Error copy is warm and friendly — the mapping lives in
//  `AuthService.friendlyAuthMessage` as a pure function so it is unit-testable.
//

import Foundation

// MARK: - Persisted state

/// The signed-in account, persisted as one Keychain blob across launches.
struct AuthState: Codable, Equatable {
    var email: String
    var uid: String
    var refreshToken: String
    var idToken: String
    /// Epoch seconds when `idToken` stops working (~1 h after issue).
    var expiresAt: TimeInterval
}

// MARK: - Errors (already phrased in warm copy)

/// A cloud problem the UI can show directly — the message is always friendly.
enum CloudError: Error, Equatable {
    /// Something to show inline, already in plain words.
    case friendly(String)
    /// The refresh token was revoked (refresh returned 400) — sign out locally.
    case signedOut

    var message: String {
        switch self {
        case .friendly(let m): return m
        case .signedOut: return "You were signed out — please sign in again to keep backing up."
        }
    }
}

// MARK: - Auth service

enum AuthService {
    private static let identityBase = "https://identitytoolkit.googleapis.com/v1"
    private static let refreshURL = "https://securetoken.googleapis.com/v1/token"
    private static let keychainAccount = "auth-state"
    /// Refresh proactively when the token has less than this long left (spec: 5 min).
    private static let refreshLeewaySeconds: TimeInterval = 5 * 60

    /// Fallback copy for network trouble and anything unrecognized.
    static let offlineMessage =
        "Couldn't reach the cloud right now — your data is safe on this device."

    // MARK: API key (bundled plist, never hardcoded)

    /// The Firebase web API key from the bundled GoogleService-Info.plist.
    static func apiKey(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["API_KEY"] as? String
    }

    // MARK: Persistence

    static func loadPersisted() -> AuthState? {
        KeychainStore.load(AuthState.self, account: keychainAccount)
    }

    static func persist(_ state: AuthState) {
        KeychainStore.save(state, account: keychainAccount)
    }

    static func clearPersisted() {
        KeychainStore.delete(account: keychainAccount)
    }

    // MARK: Friendly error copy (pure, unit-tested)

    /// Map a Firebase `error.message` code to warm copy per docs/CLOUD_SYNC.md.
    /// Codes may carry suffixes (e.g. "WEAK_PASSWORD : Password should be…"),
    /// so everything matches by prefix. Unknown / nil → the offline fallback.
    static func friendlyAuthMessage(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return offlineMessage }
        if code.hasPrefix("EMAIL_EXISTS") {
            return "That email already has an account — try signing in instead."
        }
        if code.hasPrefix("INVALID_LOGIN_CREDENTIALS")
            || code.hasPrefix("INVALID_PASSWORD")
            || code.hasPrefix("EMAIL_NOT_FOUND") {
            return "That email and password don't match — have another look and try again."
        }
        if code.hasPrefix("WEAK_PASSWORD") {
            return "Passwords need at least 6 characters."
        }
        if code.hasPrefix("INVALID_EMAIL") {
            return "That doesn't look like an email address yet."
        }
        if code.hasPrefix("TOO_MANY_ATTEMPTS_TRY_LATER") {
            return "Lots of tries in a row — take a short break and try again."
        }
        if code.hasPrefix("CONFIGURATION_NOT_FOUND") {
            return "Cloud accounts aren't switched on for this build yet."
        }
        // Federated (Google/Apple) additions per docs/CLOUD_OAUTH.md.
        if code.hasPrefix("FEDERATED_USER_ID_ALREADY_LINKED") {
            return "That email is already signed up a different way — try that instead."
        }
        if code.hasPrefix("MISSING_OR_INVALID_NONCE") {
            return "Couldn't finish signing you in — please try again."
        }
        return offlineMessage
    }

    // MARK: Sign up / sign in

    static func signUp(email: String, password: String) async throws -> AuthState {
        try await passwordCall("accounts:signUp", email: email, password: password)
    }

    static func signIn(email: String, password: String) async throws -> AuthState {
        try await passwordCall("accounts:signInWithPassword", email: email, password: password)
    }

    private static func passwordCall(_ action: String, email: String,
                                     password: String) async throws -> AuthState {
        guard let key = apiKey(),
              let url = URL(string: "\(identityBase)/\(action)?key=\(key)") else {
            throw CloudError.friendly(friendlyAuthMessage("CONFIGURATION_NOT_FOUND"))
        }
        let body: [String: Any] = ["email": email, "password": password,
                                   "returnSecureToken": true]
        let data = try await postJSON(url, body: body)
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let lifetime = TimeInterval(token.expiresIn) else {
            throw CloudError.friendly(offlineMessage)
        }
        let state = AuthState(email: token.email ?? email,
                              uid: token.localId,
                              refreshToken: token.refreshToken,
                              idToken: token.idToken,
                              expiresAt: Date().timeIntervalSince1970 + lifetime)
        persist(state)
        return state
    }

    // MARK: Federated sign-in (Google / Apple)

    /// Provider ids Firebase understands for the two federated flows we support.
    enum IdpProvider: String {
        case google = "google.com"
        case apple = "apple.com"
    }

    /// The URL an https redirect must be registered for the project (spec: any
    /// https URL the project owns). Used only as `requestUri`, never navigated to.
    static let idpRequestURI = "https://monivitals.firebaseapp.com"

    /// Build the `postBody` for `accounts:signInWithIdp` (pure, unit-tested).
    /// Apple requires the RAW nonce appended so Firebase can re-hash and compare
    /// against the `nonce` claim in the Apple JWT; Google never carries a nonce.
    static func signInWithIdpPostBody(idToken: String, providerId: String,
                                      rawNonce: String?) -> String {
        var body = "id_token=\(idToken)&providerId=\(providerId)"
        if let rawNonce, !rawNonce.isEmpty {
            body += "&nonce=\(rawNonce)"
        }
        return body
    }

    /// Exchange a provider `id_token` for a Firebase session via Identity Toolkit
    /// `accounts:signInWithIdp`, then persist the SAME `AuthState` the password
    /// path stores. Google/Apple both funnel through here so all downstream sync,
    /// keychain and prefs code is reused verbatim.
    ///
    /// - Parameters:
    ///   - idToken: the JWT from Google (via PKCE) or Apple (native).
    ///   - providerId: `google.com` or `apple.com`.
    ///   - rawNonce: the RAW (unhashed) nonce for Apple; nil for Google.
    ///   - fallbackEmail: an email captured client-side on first Apple sign-in
    ///     (Apple omits it on later logins) — used only when the response has none.
    static func completeIdpSignIn(idToken: String, providerId: IdpProvider,
                                  rawNonce: String? = nil,
                                  fallbackEmail: String? = nil) async throws -> AuthState {
        guard let key = apiKey(),
              let url = URL(string: "\(identityBase)/accounts:signInWithIdp?key=\(key)") else {
            throw CloudError.friendly(friendlyAuthMessage("CONFIGURATION_NOT_FOUND"))
        }
        let postBody = signInWithIdpPostBody(idToken: idToken,
                                             providerId: providerId.rawValue,
                                             rawNonce: rawNonce)
        let body: [String: Any] = [
            "postBody": postBody,
            "requestUri": idpRequestURI,
            "returnSecureToken": true,
            "returnIdpCredential": true,
        ]
        let data = try await postJSON(url, body: body)
        guard let token = try? JSONDecoder().decode(IdpResponse.self, from: data),
              let lifetime = TimeInterval(token.expiresIn) else {
            throw CloudError.friendly(offlineMessage)
        }
        // Apple may omit email on subsequent logins — fall back to the email we
        // cached at first sign-in, else derive a gentle label from the uid.
        let email = token.email ?? fallbackEmail ?? "Signed in with \(providerId == .apple ? "Apple" : "Google")"
        let state = AuthState(email: email,
                              uid: token.localId,
                              refreshToken: token.refreshToken,
                              idToken: token.idToken,
                              expiresAt: Date().timeIntervalSince1970 + lifetime)
        persist(state)
        return state
    }

    // MARK: Refresh (proactive)

    /// Return a state whose idToken is good for at least ~5 more minutes,
    /// refreshing (and re-persisting) when needed. A 400 from the token
    /// endpoint means the token was revoked → `CloudError.signedOut`.
    static func freshState(_ state: AuthState) async throws -> AuthState {
        if state.expiresAt - Date().timeIntervalSince1970 > refreshLeewaySeconds {
            return state
        }
        guard let key = apiKey(),
              let url = URL(string: "\(refreshURL)?key=\(key)") else {
            throw CloudError.friendly(friendlyAuthMessage("CONFIGURATION_NOT_FOUND"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let rt = state.refreshToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? state.refreshToken
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(rt)".utf8)
        await req.attachAppCheck()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudError.friendly(offlineMessage)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.friendly(offlineMessage)
        }
        if http.statusCode == 400 { throw CloudError.signedOut }
        guard (200..<300).contains(http.statusCode),
              let token = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              let lifetime = TimeInterval(token.expires_in) else {
            throw CloudError.friendly(offlineMessage)
        }
        let fresh = AuthState(email: state.email,
                              uid: token.user_id,
                              refreshToken: token.refresh_token,
                              idToken: token.id_token,
                              expiresAt: Date().timeIntervalSince1970 + lifetime)
        persist(fresh)
        return fresh
    }

    // MARK: Delete account

    /// Delete the Firebase account itself (the caller wipes cloud docs first).
    static func deleteAccount(idToken: String) async throws {
        guard let key = apiKey(),
              let url = URL(string: "\(identityBase)/accounts:delete?key=\(key)") else {
            throw CloudError.friendly(friendlyAuthMessage("CONFIGURATION_NOT_FOUND"))
        }
        _ = try await postJSON(url, body: ["idToken": idToken])
    }

    // MARK: Plumbing

    private struct TokenResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let localId: String
        let email: String?
        let expiresIn: String
    }

    /// `accounts:signInWithIdp` mirrors the password response shape.
    private struct IdpResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let localId: String
        let email: String?
        let expiresIn: String
    }

    /// The token endpoint answers in snake_case (per spec).
    private struct RefreshResponse: Decodable {
        let id_token: String
        let refresh_token: String
        let user_id: String
        let expires_in: String
    }

    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner?
    }

    /// POST a JSON body; non-2xx maps the Firebase error code to friendly copy.
    private static func postJSON(_ url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        await req.attachAppCheck()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudError.friendly(offlineMessage)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.friendly(offlineMessage)
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?
                .error?.message
            throw CloudError.friendly(friendlyAuthMessage(code))
        }
        return data
    }
}
