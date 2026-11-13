import XCTest
@testable import NevermoreCore

/// A `URLProtocol` stub so the loader tests never touch the real network.
private final class StubURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        /// Delivers the body in pieces of this size instead of at once.
        var chunkSize: Int?
    }

    private static let state = StubState()

    static func install(_ handler: @escaping (URLRequest) -> Response) {
        state.install(handler)
    }

    static func requests() -> [URLRequest] {
        state.requests()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.state.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request)
        let url = request.url ?? URL(string: "https://stub.example/")!
        let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if [301, 302, 303, 307, 308].contains(response.statusCode) {
            let location = response.headers["Location"] ?? "/"
            let target = URL(string: location, relativeTo: request.url!)!.absoluteURL
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: http)
            // The stub finishes loading so the task completes when the
            // loader stops the redirect chain.
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        for start in stride(from: 0, to: response.body.count, by: response.chunkSize ?? max(response.body.count, 1)) {
            let end = min(start + (response.chunkSize ?? response.body.count), response.body.count)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: start..<end))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The stub's mutable state lives behind a lock so the static instance
/// stays immutable and concurrency-safe.
private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) -> StubURLProtocol.Response)?
    private var recorded: [URLRequest] = []

    func install(_ handler: @escaping (URLRequest) -> StubURLProtocol.Response) {
        lock.lock()
        self.handler = handler
        recorded = []
        lock.unlock()
    }

    func record(_ request: URLRequest) -> ((URLRequest) -> StubURLProtocol.Response)? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return handler
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private struct FakeResolver: LinkPreviewHostResolving {
    let addressesByHost: [String: [LinkPreviewPolicy.Address]]

    func addresses(for host: String) async -> [LinkPreviewPolicy.Address] {
        addressesByHost[host] ?? []
    }
}

final class LinkPreviewLoaderTests: XCTestCase {
    private static let publicAddress = LinkPreviewPolicy.Address.v4(93, 184, 216, 34)
    private static let privateAddress = LinkPreviewPolicy.Address.v4(192, 168, 1, 1)
    private static let userAgent = "Mozilla/5.0 (Macintosh) link-preview facebookexternalhit/1.1 Twitterbot/1.0"
    private static let acceptHeader = "text/html,application/xhtml+xml;q=0.9"

    override func setUp() {
        super.setUp()
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 500, headers: [:], body: Data())
        }
    }

    private func makeLoader(hosts: [String: [LinkPreviewPolicy.Address]] = [:]) -> LinkPreviewLoader {
        LinkPreviewLoader(resolver: FakeResolver(addressesByHost: hosts), protocolClasses: [StubURLProtocol.self])
    }

    private static func htmlBody(title: String, image: String? = nil) -> Data {
        let imageMeta = image.map { "<meta property=\"og:image\" content=\"\($0)\">" } ?? ""
        return ("<html><head><meta property=\"og:title\" content=\"\(title)\"><meta property=\"og:description\" content=\"Summary.\">\(imageMeta)</head><body></body></html>").data(using: .utf8)!
    }

    func testPreviewSuccessAndRequestHeaders() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Self.htmlBody(title: "Preview Title"))
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
        XCTAssertEqual(preview?.title, "Preview Title")
        XCTAssertEqual(preview?.summary, "Summary.")
        XCTAssertEqual(preview?.siteName, "news.example.com")
        XCTAssertEqual(preview?.url, URL(string: "https://news.example.com/article")!)

        let requests = StubURLProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), Self.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), Self.acceptHeader)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testNonHTMLContentTypeGivesNil() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
        XCTAssertNil(preview)
    }

    func testStatus404GivesNil() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 404, headers: ["Content-Type": "text/html"], body: Data())
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/missing")!)
        XCTAssertNil(preview)
    }

    func testIneligibleAddressMakesNoRequest() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html"], body: Self.htmlBody(title: "T"))
        }
        for string in ["https://192.168.1.1/article", "http://news.example.com/article", "https://printer.local/article"] {
            let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
            let preview = await loader.preview(for: URL(string: string)!)
            XCTAssertNil(preview, string)
            XCTAssertEqual(StubURLProtocol.requests().count, 0, string)
        }
    }

    func testResolverReturningPrivateAddressMakesNoRequest() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html"], body: Self.htmlBody(title: "T"))
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.privateAddress]])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
        XCTAssertNil(preview)
        XCTAssertEqual(StubURLProtocol.requests().count, 0)
    }

    func testResolverReturningNoAddressMakesNoRequest() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html"], body: Self.htmlBody(title: "T"))
        }
        let loader = makeLoader()
        let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
        XCTAssertNil(preview)
        XCTAssertEqual(StubURLProtocol.requests().count, 0)
    }

    func testRedirectToEligibleHostIsFollowed() async {
        StubURLProtocol.install { request in
            if request.url?.host == "news.example.com" {
                return StubURLProtocol.Response(statusCode: 302, headers: ["Location": "https://cdn.example.com/article"], body: Data())
            }
            return StubURLProtocol.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Self.htmlBody(title: "Redirected", image: "/cover.png")
            )
        }
        let loader = makeLoader(hosts: [
            "news.example.com": [Self.publicAddress],
            "cdn.example.com": [Self.publicAddress],
        ])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
        XCTAssertEqual(preview?.title, "Redirected")
        XCTAssertEqual(preview?.imageURL, URL(string: "https://cdn.example.com/cover.png"))
        XCTAssertEqual(StubURLProtocol.requests().count, 2)
    }

    func testRedirectToIneligibleAddressGivesNil() async {
        for location in ["http://example.com/", "https://192.168.1.1/", "https://intranet.local/"] {
            StubURLProtocol.install { _ in
                StubURLProtocol.Response(statusCode: 302, headers: ["Location": location], body: Data())
            }
            let loader = makeLoader(hosts: [
                "news.example.com": [Self.publicAddress],
                "example.com": [Self.publicAddress],
            ])
            let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
            XCTAssertNil(preview, location)
            XCTAssertEqual(StubURLProtocol.requests().count, 1, location)
        }
    }

    func testRedirectToAnotherSchemeOrToCredentialsGivesNil() async {
        for location in ["file:///etc/passwd", "ftp://example.com/file", "https://user:pw@example.com/article", "https://example.com:8443/article"] {
            StubURLProtocol.install { _ in
                StubURLProtocol.Response(statusCode: 302, headers: ["Location": location], body: Data())
            }
            let loader = makeLoader(hosts: [
                "news.example.com": [Self.publicAddress],
                "example.com": [Self.publicAddress],
            ])
            let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
            XCTAssertNil(preview, location)
            XCTAssertEqual(StubURLProtocol.requests().count, 1, location)
        }
    }

    func testTooManyRedirectsGivesNil() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 302, headers: ["Location": "https://news.example.com/loop"], body: Data())
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/article")!)
        XCTAssertNil(preview)
        XCTAssertEqual(StubURLProtocol.requests().count, LinkPreviewPolicy.maximumRedirects + 1)
    }

    func testSecondCallIsServedFromCache() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html"], body: Self.htmlBody(title: "Cached Title"))
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let url = URL(string: "https://news.example.com/article")!
        let first = await loader.preview(for: url)
        let second = await loader.preview(for: url)
        XCTAssertEqual(first?.title, "Cached Title")
        XCTAssertEqual(second?.title, "Cached Title")
        XCTAssertEqual(StubURLProtocol.requests().count, 1)
    }

    func testFailureIsCached() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 404, headers: [:], body: Data())
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let url = URL(string: "https://news.example.com/missing")!
        let first = await loader.preview(for: url)
        let second = await loader.preview(for: url)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(StubURLProtocol.requests().count, 1)
    }

    func testOversizedBodyIsCutAndParsesHead() async {
        // No "</head>" before the cap, so only the byte cap ends the transfer.
        let head = "<html><head><meta property=\"og:title\" content=\"Big Page\"><script>"
        let padding = String(repeating: "x", count: LinkPreviewPolicy.maximumHTMLBytes + 100_000)
        let body = (head + padding + "</script></head><body></body></html>").data(using: .utf8)!
        XCTAssertGreaterThan(body.count, LinkPreviewPolicy.maximumHTMLBytes)
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html"], body: body)
        }
        let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
        let preview = await loader.preview(for: URL(string: "https://news.example.com/big")!)
        XCTAssertEqual(preview?.title, "Big Page")
    }

    func testImageDataSuccess() async {
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/png"], body: image)
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        let data = await loader.imageData(for: URL(string: "https://cdn.example.com/cover.png")!)
        XCTAssertEqual(data, image)
    }

    func testImageFailureIsCached() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 404, headers: [:], body: Data())
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        let url = URL(string: "https://cdn.example.com/missing.png")!
        let first = await loader.imageData(for: url)
        let second = await loader.imageData(for: url)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(StubURLProtocol.requests().count, 1)
    }

    func testImageRequestAsksForImages() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([0x89]))
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        _ = await loader.imageData(for: URL(string: "https://cdn.example.com/cover.png")!)
        let accept = StubURLProtocol.requests().first?.value(forHTTPHeaderField: "Accept") ?? ""
        XCTAssertTrue(accept.hasPrefix("image/png"), accept)
        XCTAssertFalse(accept.contains("svg"), accept)
        XCTAssertFalse(accept.contains("html"), accept)
    }

    func testImageAnnouncedOverLimitGivesNil() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/png", "Content-Length": "\(LinkPreviewPolicy.maximumImageBytes + 1)"], body: Data([0x89]))
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        let data = await loader.imageData(for: URL(string: "https://cdn.example.com/huge.png")!)
        XCTAssertNil(data)
    }

    func testPageDeliveredInSmallChunksParses() async {
        let body = Data(("<html><head><meta property=\"og:title\" content=\"Chunked\"></HEAD><body>" + String(repeating: "x", count: 4_000) + "</body></html>").utf8)
        for chunkSize in [1, 3, 7, 64] {
            StubURLProtocol.install { _ in
                StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "text/html"], body: body, chunkSize: chunkSize)
            }
            let loader = makeLoader(hosts: ["news.example.com": [Self.publicAddress]])
            let preview = await loader.preview(for: URL(string: "https://news.example.com/chunked")!)
            XCTAssertEqual(preview?.title, "Chunked", "chunk size \(chunkSize)")
        }
    }

    func testImageDataRejectsSVG() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/svg+xml"], body: Data("<svg/>".utf8))
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        let data = await loader.imageData(for: URL(string: "https://cdn.example.com/cover.svg")!)
        XCTAssertNil(data)
    }

    func testImageDataOverLimitGivesNil() async {
        let oversized = Data(repeating: 0xff, count: LinkPreviewPolicy.maximumImageBytes + 1)
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/png"], body: oversized)
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        let data = await loader.imageData(for: URL(string: "https://cdn.example.com/big.png")!)
        XCTAssertNil(data)
    }

    func testImageDataIneligibleAddressMakesNoRequest() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Response(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([0x00]))
        }
        let loader = makeLoader(hosts: ["cdn.example.com": [Self.publicAddress]])
        let data = await loader.imageData(for: URL(string: "https://192.168.1.5/cover.png")!)
        XCTAssertNil(data)
        XCTAssertEqual(StubURLProtocol.requests().count, 0)
    }
}
