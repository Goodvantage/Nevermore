import Foundation
import Testing
@testable import NevermoreCore

struct ReleaseCheckTests {
    static func manifest(version: String = "1.2.3", channel: String = "stable", app: String = "nevermore",
                         url: String? = nil, file: String = "Nevermore.dmg", size: Int64 = 10,
                         digest: String = String(repeating: "a", count: 64), schema: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "app": app, "version": version, "channel": channel,
            "downloads": ["macos": ["url": url ?? "https://apps.goodvantage.cloud/nevermore/\(version)/\(file)",
                                    "file": file, "size": size, "sha256": digest]]])
    }
    private let beta = ReleaseVersion("1.2.3-beta.2")!
    private let stable = ReleaseVersion("1.2.2")!

    @Test func channelsAndPrecedence() throws {
        #expect(ReleaseCheck.manifestURL(for: beta).lastPathComponent == "beta.json")
        #expect(ReleaseCheck.manifestURL(for: stable).lastPathComponent == "stable.json")
        #expect(try ReleaseOffer.decode(Self.manifest(), running: beta)?.version == ReleaseVersion("1.2.3"))
        #expect(try ReleaseOffer.decode(Self.manifest(version: "1.2.3-beta.10", channel: "beta"), running: beta) != nil)
        #expect(try ReleaseOffer.decode(Self.manifest(version: "1.2.3-beta.1", channel: "beta"), running: beta) == nil)
        #expect(try ReleaseOffer.decode(Self.manifest(version: "1.2.2"), running: stable) == nil)
        #expect(throws: ReleaseCheckError.self) { try ReleaseOffer.decode(Self.manifest(version: "1.3.0-beta.1", channel: "beta"), running: stable) }
    }

    @Test func rejectsInvalidContract() throws {
        for data in [try Self.manifest(schema: 2), try Self.manifest(app: "gooddrive"), try Self.manifest(channel: "beta"),
                     try Self.manifest(version: "01.2.3"), try Self.manifest(size: 0), try Self.manifest(size: -1),
                     try Self.manifest(size: 3_000_000_000), try Self.manifest(digest: "bad"), Data("not json".utf8),
                     Data(repeating: 32, count: ReleaseCheck.maximumBytes + 1)] {
            #expect(throws: ReleaseCheckError.self) { try ReleaseOffer.decode(data, running: stable) }
        }
        let noMac = Data(#"{"schema":1,"app":"nevermore","version":"1.2.3","channel":"stable","downloads":{}}"#.utf8)
        #expect(try ReleaseOffer.decode(noMac, running: stable) == nil)
    }

    @Test func browserLinksStayOnThePublishedRelease() throws {
        let badURLs = ["http://apps.goodvantage.cloud/nevermore/1.2.3/Nevermore.dmg", "file:///tmp/Nevermore.dmg",
            "https://evil.example/nevermore/1.2.3/Nevermore.dmg", "https://apps.goodvantage.cloud.evil.example/nevermore/1.2.3/Nevermore.dmg",
            "https://user:password@apps.goodvantage.cloud/nevermore/1.2.3/Nevermore.dmg",
            "https://apps.goodvantage.cloud:444/nevermore/1.2.3/Nevermore.dmg",
            "https://apps.goodvantage.cloud/nevermore/1.2.3/Nevermore.dmg?redirect=evil",
            "https://apps.goodvantage.cloud/nevermore/1.2.3/Nevermore.dmg#fragment",
            "https://apps.goodvantage.cloud/gooddrive/1.2.3/Nevermore.dmg",
            "https://apps.goodvantage.cloud/nevermore/1.2.2/Nevermore.dmg"]
        for url in badURLs { #expect(throws: ReleaseCheckError.self) { try ReleaseOffer.decode(Self.manifest(url: url), running: stable) } }
        for file in ["../Nevermore.dmg", ".", "a/b.dmg", "a%2fb.dmg", "a\\b.dmg", "a\n.dmg", ""] {
            #expect(throws: ReleaseCheckError.self) { try ReleaseOffer.decode(Self.manifest(file: file), running: stable) }
        }
        #expect(try ReleaseOffer.decode(Self.manifest(version: "1.2.3+build.7"), running: stable) != nil)
    }

    @Test func credentialFreeTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-only", "Cookie": "fixture-only"]
        let offer = try await ReleaseCheck().fetch(for: stable, configuration: configuration)
        #expect(offer?.version == ReleaseVersion("1.2.3"))
    }

    @Test func redirectDelegateRefusesEvenSameHostRedirects() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = ReleaseCheck.manifestURL(for: stable)
        let task = session.dataTask(with: original) // Never resumed.
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in ["https://apps.goodvantage.cloud/other.json", "https://evil.example/update.json", "http://127.0.0.1/private"] {
            let allowed: URLRequest? = await withCheckedContinuation { continuation in
                ReleaseTransportBoundary().urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: URL(string: target)!), completionHandler: { continuation.resume(returning: $0) })
            }
            #expect(allowed == nil)
        }
    }

    @Test func transportRejectsErrorsAndOversizedBodies() async throws {
        for fixture in [FailureReleaseProtocol.self, DeclaredLargeReleaseProtocol.self, StreamedLargeReleaseProtocol.self, RedirectReleaseProtocol.self] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [fixture]
            await #expect(throws: ReleaseCheckError.self) { try await ReleaseCheck().fetch(for: stable, configuration: configuration) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MissingReleaseProtocol.self]
        #expect(try await ReleaseCheck().fetch(for: stable, configuration: configuration) == nil)
    }
}

private class ReleaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    class var status: Int { 200 }
    class var headers: [String: String] { ["Content-Type": "application/json"] }
    class var body: Data { try! ReleaseCheckTests.manifest() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.absoluteString == "https://apps.goodvantage.cloud/nevermore/stable.json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Nevermore/1.2.2 (macOS)")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class FailureReleaseProtocol: ReleaseFixtureProtocol, @unchecked Sendable { override class var status: Int { 500 } }
private final class MissingReleaseProtocol: ReleaseFixtureProtocol, @unchecked Sendable { override class var status: Int { 404 } }
private final class RedirectReleaseProtocol: ReleaseFixtureProtocol, @unchecked Sendable {
    override class var status: Int { 302 }
    override class var headers: [String: String] { ["Location": "https://evil.example/manifest.json"] }
}
private final class DeclaredLargeReleaseProtocol: ReleaseFixtureProtocol, @unchecked Sendable {
    override class var headers: [String: String] { ["Content-Length": "999999999"] }
}
private final class StreamedLargeReleaseProtocol: ReleaseFixtureProtocol, @unchecked Sendable {
    override class var body: Data { Data(repeating: 32, count: ReleaseCheck.maximumBytes + 1) }
}
