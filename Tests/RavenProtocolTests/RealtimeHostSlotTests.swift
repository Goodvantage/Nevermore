import Foundation
import Testing
@testable import RavenProtocol

@MainActor
struct RealtimeHostSlotSuite {
    // Each test gets a separate origin and parent in the shared cookie jar.
    private let parent = "realtime-\(UUID().uuidString.lowercased()).invalid"
    private var host: String { "socket.\(parent)" }
    private var sibling: String { "sibling.\(parent)" }
    private let jar = HTTPCookieStorage.shared

    @Test func releasingAnUncountedHostKeepsItsCookie() {
        let cookie = fixtureCookie(domain: host)
        defer { jar.deleteCookie(cookie) }
        jar.setCookie(cookie)

        RavenRealtime.releaseHostSlot(host)
        RavenRealtime.releaseHostSlot(host)

        #expect(contains(cookie))
    }

    @Test func onlyTheFirstAndLastSocketPurgeHostCookies() {
        let cookie = fixtureCookie(domain: host)
        defer { jar.deleteCookie(cookie) }
        jar.setCookie(cookie)

        RavenRealtime.acquireHostSlot(host)
        #expect(!contains(cookie))

        jar.setCookie(cookie)
        RavenRealtime.acquireHostSlot(host)
        #expect(contains(cookie))

        RavenRealtime.releaseHostSlot(host)
        #expect(contains(cookie))

        RavenRealtime.releaseHostSlot(host)
        #expect(!contains(cookie))
    }

    @Test func parentCookieSurvivesUntilTheLastSiblingLeaves() {
        let hostCookie = fixtureCookie(domain: host)
        let parentCookie = fixtureCookie(domain: ".\(parent)")
        defer { jar.deleteCookie(hostCookie); jar.deleteCookie(parentCookie) }
        RavenRealtime.acquireHostSlot(host)
        RavenRealtime.acquireHostSlot(sibling)

        jar.setCookie(hostCookie)
        jar.setCookie(parentCookie)
        RavenRealtime.releaseHostSlot(host)
        #expect(!contains(hostCookie))
        #expect(contains(parentCookie))

        RavenRealtime.releaseHostSlot(sibling)
        #expect(!contains(parentCookie))
    }

    private func fixtureCookie(domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: "test-slot", .value: "1"])!
    }

    private func contains(_ cookie: HTTPCookie) -> Bool {
        jar.cookies?.contains { $0.domain == cookie.domain && $0.path == cookie.path && $0.name == cookie.name } == true
    }
}
