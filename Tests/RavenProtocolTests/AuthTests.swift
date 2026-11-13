import CryptoKit
import Foundation
import Testing
@testable import RavenProtocol

@Test func normalizesSiteInputToCanonicalOrigins() throws {
    #expect(try SiteOrigin.normalize("chat.example.com").absoluteString == "https://chat.example.com")
    #expect(try SiteOrigin.normalize("  HTTPS://CHAT.Example.COM/  ").absoluteString == "https://chat.example.com")
    #expect(try SiteOrigin.normalize("https://chat.example.com:8443").absoluteString == "https://chat.example.com:8443")
    #expect(try SiteOrigin.normalize("http://localhost:8000", allowLocalHTTP: true).absoluteString == "http://localhost:8000")
}

@Test func rejectsUnacceptableSiteInput() {
    for input in [
        "", "   ",
        "http://chat.example.com",          // plain HTTP is never accepted for real sites
        "http://192.168.1.5",               // HTTP off-loopback stays refused even with the flag
        "https://user:secret@chat.example.com",
        "https://chat.example.com/raven",
        "https://chat.example.com/?x=1",
        "https://chat.example.com/#frag",
        "ftp://chat.example.com",
        "not a url",
    ] {
        #expect(throws: RavenError.self) { try SiteOrigin.normalize(input, allowLocalHTTP: true) }
    }
}

@Test func sameOriginComparesEffectivePorts() {
    let base = URL(string: "https://chat.example.com")!
    #expect(SiteOrigin.sameOrigin(base, URL(string: "https://chat.example.com:443/private/files/a.png")!))
    #expect(SiteOrigin.sameOrigin(base, URL(string: "https://chat.example.com/api/method/x")!))
    #expect(!SiteOrigin.sameOrigin(base, URL(string: "https://chat.example.com:8443")!))
    #expect(!SiteOrigin.sameOrigin(base, URL(string: "http://chat.example.com")!))
    #expect(!SiteOrigin.sameOrigin(base, URL(string: "https://evil.example.com")!))
    #expect(SiteOrigin.sameOrigin(URL(string: "http://localhost:8000")!, URL(string: "http://localhost:8000/socket.io/")!))
    #expect(!SiteOrigin.sameOrigin(URL(string: "http://localhost:8000")!, URL(string: "http://localhost")!))
}

@Test func oauthClientListURLStaysOnTheEnteredOrigin() throws {
    func list(_ input: String, allowLocalHTTP: Bool = false) throws -> String? {
        RavenEndpoints.oauthClientListURL(origin: try SiteOrigin.normalize(input, allowLocalHTTP: allowLocalHTTP))?.absoluteString
    }
    #expect(try list("chat.example.com") == "https://chat.example.com/desk/integrations/oauth-client")
    #expect(try list("  HTTPS://CHAT.Example.COM/  ") == "https://chat.example.com/desk/integrations/oauth-client")
    #expect(try list("https://chat.example.com:8443") == "https://chat.example.com:8443/desk/integrations/oauth-client")
    #expect(try list("https://[2001:db8::1]:8443") == "https://[2001:db8::1]:8443/desk/integrations/oauth-client")
    #expect(try list("http://localhost:8000", allowLocalHTTP: true) == "http://localhost:8000/desk/integrations/oauth-client")
    // Only the scheme, host and port are taken from the origin: no path,
    // query, fragment or credentials reach the page the browser opens.
    let url = try #require(RavenEndpoints.oauthClientListURL(origin: URL(string: "https://user:secret@chat.example.com/raven?next=x#frag")!))
    #expect(url.absoluteString == "https://chat.example.com/desk/integrations/oauth-client")
}

@Test func pkceGeneratesVerifierStateAndS256Challenge() {
    let transaction = PKCETransaction()
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    for value in [transaction.state, transaction.verifier] {
        #expect(value.count == 43)
        #expect(value.unicodeScalars.allSatisfy(unreserved.contains))
    }
    // RFC 7636: challenge = BASE64URL(SHA256(verifier)), no padding.
    let expected = Data(SHA256.hash(data: Data(transaction.verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(transaction.challenge == expected)
    #expect(transaction.challenge != transaction.verifier)
    #expect(PKCETransaction().verifier != transaction.verifier)
}

@Test func authorizationURLCarriesExactOAuthParameters() throws {
    let transaction = PKCETransaction()
    let origin = URL(string: "https://chat.example.com")!
    let redirect = URL(string: "ch.goodvantage.Nevermore://oauth")!
    let url = try transaction.authorizationURL(origin: origin, clientID: "client-123", redirectURI: redirect)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(url.scheme == "https" && url.host == "chat.example.com")
    #expect(components.path == "/api/method/frappe.integrations.oauth2.authorize")
    let items = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
    #expect(items["client_id"] == "client-123")
    #expect(items["redirect_uri"] == "ch.goodvantage.Nevermore://oauth")
    #expect(items["response_type"] == "code")
    #expect(items["scope"] == "all openid")
    #expect(items["state"] == transaction.state)
    #expect(items["code_challenge"] == transaction.challenge)
    #expect(items["code_challenge_method"] == "S256")
}

@Test func callbackValidationEnforcesStateAndRedirectURI() throws {
    let transaction = PKCETransaction()
    let redirect = URL(string: "ch.goodvantage.Nevermore://oauth")!
    let good = URL(string: "ch.goodvantage.Nevermore://oauth?code=abc123&state=\(transaction.state)")!
    #expect(try transaction.validateCallback(good, redirectURI: redirect) == "abc123")

    for callback in [
        "ch.goodvantage.Nevermore://oauth?code=abc123&state=wrong",
        "ch.goodvantage.Nevermore://oauth?code=abc123",
        "ch.goodvantage.Nevermore://oauth?state=\(transaction.state)",
        "ch.goodvantage.Nevermore://other?code=abc123&state=\(transaction.state)",
        "https://ch.goodvantage.Nevermore/oauth?code=abc123&state=\(transaction.state)",
        "ch.goodvantage.Nevermore://oauth?code=&state=\(transaction.state)",
        "ch.goodvantage.Nevermore://oauth?error=access_denied&state=\(transaction.state)",
    ] {
        #expect(throws: RavenError.self) { try transaction.validateCallback(URL(string: callback)!, redirectURI: redirect) }
    }
}

@Test func oauthTokensRoundTripAndExpirySemantics() throws {
    let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3000))
    #expect(try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(tokens)) == tokens)
    #expect(!tokens.needsRefresh())
    #expect(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date()).needsRefresh())
    #expect(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(30)).needsRefresh())
}

@Test(.enabled(if: TestKeychain.isWritable, TestKeychain.unavailableReason)) func keychainPersistsTokensPerAccount() throws {
    let first = UUID(), second = UUID()
    let tokens = OAuthTokens(accessToken: "a1", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600))
    defer { try? KeychainTokenStore.delete(accountID: first); try? KeychainTokenStore.delete(accountID: second) }
    try KeychainTokenStore.save(tokens, accountID: first)
    #expect(try KeychainTokenStore.load(accountID: first) == tokens)
    #expect(try KeychainTokenStore.load(accountID: second) == nil)
    let refreshed = OAuthTokens(accessToken: "a2", refreshToken: "r2", expiresAt: Date().addingTimeInterval(7200))
    try KeychainTokenStore.save(refreshed, accountID: first)
    #expect(try KeychainTokenStore.load(accountID: first) == refreshed)
    try KeychainTokenStore.delete(accountID: first)
    #expect(try KeychainTokenStore.load(accountID: first) == nil)
}

@Test func errorsStayLocalizedAndRedacted() throws {
    let denied = RavenError.http(403, "PermissionError")
    #expect(denied.isPermissionDenied)
    #expect(denied.isPermanent)
    let description = try #require(denied.errorDescription)
    #expect(description.contains("403") && description.contains("PermissionError"))
    #expect(!description.contains("traceback") && !description.contains("File \""))

    #expect(RavenError.http(401, nil).isPermissionDenied)
    #expect(RavenError.http(417, "ValidationError").isPermanent)
    #expect(!RavenError.http(500, nil).isPermanent)
    #expect(!RavenError.http(429, nil).isPermanent)
    #expect(RavenError.unauthorized.isPermissionDenied)
    #expect(RavenError.unauthorized.isPermanent)
    #expect(!RavenError.transport.isPermanent)
    #expect(!RavenError.transport.isPermissionDenied)
    #expect(RavenError.crossOrigin.isPermanent)
    #expect(RavenError.oauth("temporarily_unavailable").isPermanent == false)
    #expect(RavenError.oauth("invalid_grant").isPermanent)

    // Free-text server fields never leak: descriptions use status and class names only.
    for error in [RavenError.invalidSite, .transport, .oauth("invalid_grant"), .unauthorized, .invalidResponse, .crossOrigin, .keychain(-25299), .http(503, nil)] {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
