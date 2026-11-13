import CryptoKit
import Foundation

/// One authorization-code + PKCE transaction. `state` and `verifier` are fresh
/// secrets per attempt; `challenge` is their public S256 commitment.
public struct PKCETransaction: Sendable {
    public let state: String
    public let verifier: String
    public let challenge: String

    public init() {
        state = Self.randomURLSafe()
        verifier = Self.randomURLSafe()
        challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Builds the Frappe authorization URL (GET). The caller presents it in
    /// ASWebAuthenticationSession; Nevermore never sees credentials.
    public func authorizationURL(origin: URL, clientID: String, redirectURI: URL) throws -> URL {
        var components = URLComponents(url: URL(string: RavenEndpoints.authorizePath, relativeTo: origin) ?? origin, resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "all openid"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else { throw RavenError.invalidSite }
        return url
    }

    /// Validates the browser callback and returns the authorization code.
    /// The callback must match the registered redirect URI's scheme/host/path
    /// exactly and carry back this transaction's state.
    public func validateCallback(_ url: URL, redirectURI: URL) throws -> String {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme?.lowercased() == redirectURI.scheme?.lowercased(),
              url.host?.lowercased() == redirectURI.host?.lowercased(),
              SiteOrigin.port(url) == SiteOrigin.port(redirectURI),
              url.path(percentEncoded: false) == redirectURI.path(percentEncoded: false) else {
            throw RavenError.oauth("redirect_uri_mismatch")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw RavenError.oauth("invalid_callback") }
        let query = components.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count else { throw RavenError.oauth("invalid_callback") }
        let items = Dictionary(components.queryItems?.compactMap { $0.value == nil ? nil : ($0.name, $0.value!) } ?? [], uniquingKeysWith: { a, _ in a })
        if let error = items["error"] { throw RavenError.oauth(RavenError.sanitizedOAuthCode(error)) }
        guard items["state"] == state else { throw RavenError.oauth("state_mismatch") }
        guard let code = items["code"], !code.isEmpty else { throw RavenError.oauth("missing_code") }
        return code
    }

    static func randomURLSafe() -> String {
        base64url(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
