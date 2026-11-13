import Foundation
import Testing
@testable import RavenProtocol

@Test func callbackRejectsCredentialsFragmentsAndDuplicateQueryParameters() throws {
    let transaction = PKCETransaction()
    let redirect = URL(string: "ch.goodvantage.Nevermore://oauth")!
    let state = transaction.state
    for text in [
        "ch.goodvantage.Nevermore://intruder@oauth?state=\(state)&code=ok",
        "ch.goodvantage.Nevermore://oauth?state=\(state)&code=ok#ignored",
        "ch.goodvantage.Nevermore://oauth?state=\(state)&state=other&code=ok",
        "ch.goodvantage.Nevermore://oauth?state=\(state)&code=one&code=two"
    ] {
        #expect(throws: (any Error).self) { try transaction.validateCallback(URL(string: text)!, redirectURI: redirect) }
    }
    #expect(try transaction.validateCallback(URL(string: "ch.goodvantage.Nevermore://oauth?state=\(state)&code=ok")!, redirectURI: redirect) == "ok")
}
@Test func originComparisonRejectsCredentialBearingResourceURLs() {
    let site = URL(string: "https://chat.example")!
    #expect(!SiteOrigin.sameOrigin(URL(string: "https://user@chat.example/private/file")!, site))
    #expect(!SiteOrigin.sameOrigin(URL(string: "https://chat.example.evil/private/file")!, site))
    #expect(!SiteOrigin.sameOrigin(URL(string: "http://chat.example/private/file")!, site))
    #expect(!SiteOrigin.sameOrigin(URL(string: "https://chat.example:444/private/file")!, site))
    #expect(SiteOrigin.sameOrigin(URL(string: "https://chat.example:443/private/file")!, site))
}
