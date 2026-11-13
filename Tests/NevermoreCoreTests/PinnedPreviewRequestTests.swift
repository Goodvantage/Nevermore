import XCTest
@testable import NevermoreCore

final class PinnedPreviewRequestTests: XCTestCase {
    private let url = URL(string: "https://news.example.com/article")!
    private let publicAddress = LinkPreviewPolicy.Address.v4(93, 184, 216, 34)

    func testNativeTransportUsesCheckedAddressInsteadOfResolvingAgain() {
        // localhost normally resolves to loopback. Supply a checked public
        // answer instead, and observe libcurl's actual socket endpoint.
        // The observer rejects it before socket(), so no network is used.
        let attempts = SocketAttempts()
        let result = PinnedPreviewRequest.perform(URL(string: "https://localhost/")!, addresses: [publicAddress], kind: .html, userAgent: "fixture") {
            attempts.record($0)
            return false
        }
        XCTAssertNil(result)
        XCTAssertEqual(attempts.values, [publicAddress])
    }

    func testNativeTransportPinsIPv6Too() {
        let address = LinkPreviewPolicy.Address.v6([0x26, 0x06, 0x47, 0x00] + Array(repeating: 0, count: 11) + [1])
        let attempts = SocketAttempts()
        let result = PinnedPreviewRequest.perform(URL(string: "https://localhost/")!, addresses: [address], kind: .html, userAgent: "fixture") {
            attempts.record($0)
            return false
        }
        XCTAssertNil(result)
        XCTAssertEqual(attempts.values, [address])
    }

    func testMixedOrEmptyAnswersNeverOpenASocket() {
        for addresses in [[], [publicAddress, .v4(127, 0, 0, 1)], [.v4(192, 168, 1, 1)]] {
            let attempts = SocketAttempts()
            let result = PinnedPreviewRequest.perform(url, addresses: addresses, kind: .html, userAgent: "fixture") {
                attempts.record($0)
                return false
            }
            XCTAssertNil(result)
            XCTAssertTrue(attempts.values.isEmpty)
        }
    }

    func testHeadersAndBodyProduceAnHTTPResponse() {
        let buffer = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertTrue(headers(buffer, lines: ["HTTP/1.1 200 OK", "Content-Type: text/html; charset=utf-8", "Set-Cookie: first=1", "Set-Cookie: second=2", ""]))
        XCTAssertTrue(buffer.receiveBody(Data("<title>Title</title>".utf8)))
        let result = buffer.result(succeeded: true)
        XCTAssertEqual((result?.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((result?.response as? HTTPURLResponse)?.textEncodingName, "utf-8")
        XCTAssertEqual(result?.body, Data("<title>Title</title>".utf8))
    }

    func testHTMLStopsAtHeadEndSplitAcrossChunks() {
        let buffer = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertTrue(headers(buffer, lines: ["HTTP/1.1 200 OK", "Content-Type: text/html", ""]))
        XCTAssertTrue(buffer.receiveBody(Data("<title>Title</title></HE".utf8)))
        XCTAssertFalse(buffer.receiveBody(Data("AD><body>unused".utf8)))
        XCTAssertNotNil(buffer.result(succeeded: false)?.body)
    }

    func testHTMLKeepsOnlyTheBoundedDecodedPrefix() {
        let buffer = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertTrue(headers(buffer, lines: ["HTTP/1.1 200 OK", "Content-Type: text/html", ""]))
        XCTAssertFalse(buffer.receiveBody(Data(repeating: 65, count: LinkPreviewPolicy.maximumHTMLBytes + 10)))
        XCTAssertEqual(buffer.result(succeeded: false)?.body?.count, LinkPreviewPolicy.maximumHTMLBytes)
    }

    func testImagesRejectOversizedBodiesAndContentLengths() {
        let announced = PinnedPreviewRequest.Buffer(url: url, kind: .image)
        XCTAssertFalse(headers(announced, lines: ["HTTP/1.1 200 OK", "Content-Type: image/png", "Content-Length: \(LinkPreviewPolicy.maximumImageBytes + 1)", ""]))
        XCTAssertNil(announced.result(succeeded: false))

        let streamed = PinnedPreviewRequest.Buffer(url: url, kind: .image)
        XCTAssertTrue(headers(streamed, lines: ["HTTP/1.1 200 OK", "Content-Type: image/png", ""]))
        XCTAssertFalse(streamed.receiveBody(Data(repeating: 65, count: LinkPreviewPolicy.maximumImageBytes + 1)))
        XCTAssertNil(streamed.result(succeeded: false))
    }

    func testRedirectStopsBeforeTheBodyAndPreservesLocation() {
        let buffer = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertFalse(headers(buffer, lines: ["HTTP/1.1 302 Found", "Location: https://elsewhere.example/path", ""]))
        let result = buffer.result(succeeded: false)
        XCTAssertEqual((result?.response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertEqual((result?.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), "https://elsewhere.example/path")
        XCTAssertEqual(result?.body, Data())
        XCTAssertFalse(buffer.receiveBody(Data("never read".utf8)))
    }

    func testWrongTypesHeadersAndInterruptedBodiesFailClosed() {
        let wrongType = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertFalse(headers(wrongType, lines: ["HTTP/1.1 200 OK", "Content-Type: application/json", ""]))
        XCTAssertNil(wrongType.result(succeeded: false))

        let duplicate = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertFalse(headers(duplicate, lines: ["HTTP/1.1 200 OK", "Content-Type: text/html", "Content-Type: image/png"]))
        XCTAssertNil(duplicate.result(succeeded: false))

        let huge = PinnedPreviewRequest.Buffer(url: url, kind: .html)
        XCTAssertFalse(huge.receiveHeader(Data(repeating: 65, count: 65 * 1024)))
        XCTAssertNil(huge.result(succeeded: false))

        let interrupted = PinnedPreviewRequest.Buffer(url: url, kind: .image)
        XCTAssertTrue(headers(interrupted, lines: ["HTTP/1.1 200 OK", "Content-Type: image/png", ""]))
        XCTAssertTrue(interrupted.receiveBody(Data([1, 2, 3])))
        XCTAssertNil(interrupted.result(succeeded: false)?.body)
    }

    func testInterimResponsesAndTrailersCannotOverrideFinalHeaders() {
        let buffer = PinnedPreviewRequest.Buffer(url: url, kind: .image)
        XCTAssertTrue(headers(buffer, lines: ["HTTP/1.1 103 Early Hints", "Link: </style.css>", "", "HTTP/1.1 200 OK", "Content-Type: image/png", ""]))
        XCTAssertTrue(buffer.receiveBody(Data([1, 2, 3])))
        XCTAssertTrue(headers(buffer, lines: ["Content-Type: text/html", ""]))
        XCTAssertEqual((buffer.result(succeeded: true)?.response as? HTTPURLResponse)?.mimeType, "image/png")
    }

    private func headers(_ buffer: PinnedPreviewRequest.Buffer, lines: [String]) -> Bool {
        for line in lines where !buffer.receiveHeader(Data((line + "\r\n").utf8)) { return false }
        return true
    }
}

private final class SocketAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LinkPreviewPolicy.Address] = []

    func record(_ address: LinkPreviewPolicy.Address) {
        lock.withLock { recorded.append(address) }
    }

    var values: [LinkPreviewPolicy.Address] { lock.withLock { recorded } }
}
