//
//  GoogleSignIn.swift
//  MoniVitals
//
//  "Continue with Google" without the Firebase/Google SDK: a native OAuth 2.0
//  authorization-code flow with PKCE (RFC 7636) driven by ASWebAuthenticationSession,
//  then a token exchange to obtain the Google `id_token`. That token is handed to
//  AuthService.completeIdpSignIn, which swaps it for a Firebase session and persists
//  the same AuthState the email/password path uses (docs/CLOUD_OAUTH.md).
//
//  The URL / body / PKCE builders are pure static funcs so they unit-test without
//  any network or UI. The interactive session is the only impure part.
//

import AuthenticationServices
import CryptoKit
import Foundation

// MARK: - PKCE (pure, unit-tested)

/// Proof Key for Code Exchange helpers (RFC 7636). `code_challenge` is
/// base64url(SHA256(code_verifier)) with no padding.
enum PKCE {
    /// The unreserved characters allowed in a PKCE `code_verifier` (RFC 7636 §4.1):
    /// ALPHA / DIGIT / "-" / "." / "_" / "~".
    static let verifierAllowed =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    /// Generate a random 43–128 character `code_verifier` from the unreserved set.
    static func makeVerifier(length: Int = 64) -> String {
        let clamped = min(max(length, 43), 128)
        let chars = Array(verifierAllowed)
        var out = ""
        out.reserveCapacity(clamped)
        for _ in 0..<clamped {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
    }

    /// base64url(SHA256(verifier)) with no `=` padding (pure — RFC 7636 §4.2).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLNoPadding(Data(digest))
    }

    /// Standard base64url encoding with padding stripped.
    static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Google OAuth request builders (pure, unit-tested)

/// Pure URL / form-body builders for the Google OAuth flow. Kept SDK-free and
/// network-free so they are fully unit-testable; identifiers come from the bundled
/// GoogleService-Info.plist at runtime.
enum GoogleOAuth {
    static let authorizeBase = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    /// Redirect path appended to the reversed-client-id scheme.
    static let redirectPath = "/oauth2redirect"

    /// The redirect URI: `<REVERSED_CLIENT_ID>:/oauth2redirect`.
    static func redirectURI(reversedClientId: String) -> String {
        "\(reversedClientId):\(redirectPath)"
    }

    /// Build the authorization URL that ASWebAuthenticationSession opens.
    static func authorizeURL(clientId: String, reversedClientId: String,
                             codeChallenge: String) -> URL? {
        var comps = URLComponents(string: authorizeBase)
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI(reversedClientId: reversedClientId)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return comps?.url
    }

    /// Extract the authorization `code` from the redirect callback URL.
    static func code(from callback: URL) -> String? {
        URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
    }

    /// Build the form-encoded body for the token exchange (no client secret —
    /// this is a native + PKCE public client).
    static func tokenExchangeBody(code: String, clientId: String,
                                  reversedClientId: String, codeVerifier: String) -> String {
        func esc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
        }
        return [
            "code=\(esc(code))",
            "client_id=\(esc(clientId))",
            "code_verifier=\(esc(codeVerifier))",
            "grant_type=authorization_code",
            "redirect_uri=\(esc(redirectURI(reversedClientId: reversedClientId)))",
        ].joined(separator: "&")
    }
}

private extension CharacterSet {
    /// x-www-form-urlencoded safe set (RFC 3986 unreserved), so `=` `&` `:` `/`
    /// in values are percent-escaped.
    static let urlQueryValueAllowed: CharacterSet = {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()
}

// MARK: - Interactive Google sign-in

/// Drives the Google OAuth flow end to end and returns the Firebase AuthState.
/// A user cancel throws `GoogleSignIn.Cancelled`, which callers treat as silent.
@MainActor
final class GoogleSignIn: NSObject {

    /// Thrown when the user dismisses the web sheet — surfaced as no error UI.
    struct Cancelled: Error {}

    /// Identifiers pulled from the bundled GoogleService-Info.plist.
    private struct Config {
        let clientId: String
        let reversedClientId: String
    }

    private var session: ASWebAuthenticationSession?

    private static func readConfig(bundle: Bundle = .main) -> Config? {
        guard let url = bundle.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let clientId = dict["CLIENT_ID"] as? String,
              let reversed = dict["REVERSED_CLIENT_ID"] as? String else { return nil }
        return Config(clientId: clientId, reversedClientId: reversed)
    }

    /// Run the whole flow: PKCE → web auth → code → token exchange → signInWithIdp.
    func signIn() async throws -> AuthState {
        guard let config = Self.readConfig() else {
            throw CloudError.friendly(AuthService.friendlyAuthMessage("CONFIGURATION_NOT_FOUND"))
        }
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        guard let authURL = GoogleOAuth.authorizeURL(clientId: config.clientId,
                                                     reversedClientId: config.reversedClientId,
                                                     codeChallenge: challenge) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }

        let callback = try await presentWebAuth(url: authURL,
                                                callbackScheme: config.reversedClientId)
        guard let code = GoogleOAuth.code(from: callback) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        let idToken = try await exchangeCodeForIdToken(code: code, config: config,
                                                       verifier: verifier)
        return try await AuthService.completeIdpSignIn(idToken: idToken,
                                                       providerId: .google)
    }

    private func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: Cancelled())
                    return
                }
                if error != nil {
                    continuation.resume(throwing: CloudError.friendly(AuthService.offlineMessage))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: CloudError.friendly(AuthService.offlineMessage))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Ephemeral so each sign-in starts clean — on a shared device the health
            // account can't silently bind to a previously signed-in Google identity.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: CloudError.friendly(AuthService.offlineMessage))
            }
        }
    }

    private func exchangeCodeForIdToken(code: String, config: Config,
                                        verifier: String) async throws -> String {
        guard let url = URL(string: GoogleOAuth.tokenURL) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(GoogleOAuth.tokenExchangeBody(
            code: code, clientId: config.clientId,
            reversedClientId: config.reversedClientId, codeVerifier: verifier).utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let token = try? JSONDecoder().decode(TokenExchangeResponse.self, from: data) else {
            throw CloudError.friendly(AuthService.offlineMessage)
        }
        return token.id_token
    }

    private struct TokenExchangeResponse: Decodable {
        let id_token: String
    }
}

// MARK: - Presentation context

extension GoogleSignIn: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
