import XCTest
@testable import NevermoreCore

final class LinkDetectionTests: XCTestCase {
    func testPlainAddresses() throws {
        let secure = try XCTUnwrap(LinkDetection.webAddress(in: "see https://a.example/x", endingAt: 23))
        XCTAssertEqual(secure.url, "https://a.example/x")
        XCTAssertEqual(secure.range, NSRange(location: 4, length: 19))
        let plain = try XCTUnwrap(LinkDetection.webAddress(in: "http://a.example", endingAt: 16))
        XCTAssertEqual(plain.url, "http://a.example")
        XCTAssertEqual(plain.range, NSRange(location: 0, length: 16))
    }

    func testUppercaseScheme() throws {
        let text = "HTTPS://A.EXAMPLE/X"
        let match = try XCTUnwrap(LinkDetection.webAddress(in: text, endingAt: text.utf16.count))
        XCTAssertEqual(match.url, "HTTPS://A.EXAMPLE/X")
        XCTAssertEqual(match.range, NSRange(location: 0, length: text.utf16.count))
    }

    func testTrailingPunctuationIsTrimmed() throws {
        let text = "see https://a.example/x."
        let match = try XCTUnwrap(LinkDetection.webAddress(in: text, endingAt: text.utf16.count))
        XCTAssertEqual(match.url, "https://a.example/x")
        XCTAssertEqual(match.range, NSRange(location: 4, length: 19))
    }

    func testFullwidthPunctuationIsTrimmed() throws {
        // Sentence punctuation of Chinese and Japanese text, written
        // directly after an address.
        for mark in ["\u{3002}", "\u{3001}", "\u{FF0C}", "\u{FF01}", "\u{FF1F}", "\u{FF1A}", "\u{FF1B}"] {
            let text = "see https://a.example/x" + mark
            let match = try XCTUnwrap(LinkDetection.webAddress(in: text, endingAt: text.utf16.count), text)
            XCTAssertEqual(match.url, "https://a.example/x", text)
            XCTAssertEqual(match.range, NSRange(location: 4, length: 19), text)
        }
    }

    func testInvisibleCharactersAfterAnAddressAreTrimmed() throws {
        // A zero-width space or a byte order mark picked up by copying.
        for invisible in ["\u{200B}", "\u{FEFF}"] {
            let text = "https://a.example/x" + invisible
            let match = try XCTUnwrap(LinkDetection.webAddresses(in: text).first, text.debugDescription)
            XCTAssertEqual(match.url, "https://a.example/x")
            XCTAssertEqual(match.range, NSRange(location: 0, length: 19))
        }
    }

    func testWrappedAddresses() {
        for text in ["(https://a.example/x)", "\"https://a.example/x\"", "<https://a.example/x>", "[https://a.example/x]", "'https://a.example/x'"] {
            let matches = LinkDetection.webAddresses(in: text)
            XCTAssertEqual(matches.count, 1, text)
            XCTAssertEqual(matches.first?.url, "https://a.example/x", text)
            XCTAssertEqual((text as NSString).substring(with: matches.first!.range), "https://a.example/x", text)
        }
    }

    func testCurlyQuotesAroundAnAddressAreTrimmed() {
        for text in ["\u{201C}https://a.example/x\u{201D}", "\u{2018}https://a.example/x\u{2019}"] {
            let matches = LinkDetection.webAddresses(in: text)
            XCTAssertEqual(matches.map(\.url), ["https://a.example/x"], text)
            XCTAssertEqual(matches.first?.range, NSRange(location: 1, length: 19), text)
        }
    }

    func testAddressInTheMiddleAfterEmojiHasUTF16Range() {
        let text = "🙂 see https://a.example/x, then more"
        let matches = LinkDetection.webAddresses(in: text)
        XCTAssertEqual(matches.map(\.url), ["https://a.example/x"])
        XCTAssertEqual(matches.first?.range, NSRange(location: 7, length: 19))
    }

    func testBalancedParenthesesAreKept() throws {
        let text = "https://en.wikipedia.org/wiki/Swift_(language)"
        let match = try XCTUnwrap(LinkDetection.webAddress(in: text, endingAt: text.utf16.count))
        XCTAssertEqual(match.url, text)
        XCTAssertEqual(match.range, NSRange(location: 0, length: text.utf16.count))
    }

    func testUnbalancedWrapperIsTrimmed() throws {
        let text = "(https://a.example/x)"
        let match = try XCTUnwrap(LinkDetection.webAddress(in: text, endingAt: text.utf16.count))
        XCTAssertEqual(match.url, "https://a.example/x")
        XCTAssertEqual(match.range, NSRange(location: 1, length: 19))
    }

    func testUnsupportedSchemesAreRejected() {
        for text in ["ftp://a.example", "mailto:a@example.com", "javascript:alert(1)", "example.com", "xhttps://a.example"] {
            XCTAssertTrue(LinkDetection.webAddresses(in: text).isEmpty, text)
            XCTAssertNil(LinkDetection.webAddress(in: text, endingAt: text.utf16.count), text)
        }
    }

    func testCredentialsAreRejected() {
        let text = "https://user:pw@a.example"
        XCTAssertTrue(LinkDetection.webAddresses(in: text).isEmpty)
        XCTAssertNil(LinkDetection.webAddress(in: text, endingAt: text.utf16.count))
    }

    func testAddressAfterEmojiHasUTF16Range() throws {
        let text = "🙂 https://a.example/x"
        let match = try XCTUnwrap(LinkDetection.webAddress(in: text, endingAt: text.utf16.count))
        XCTAssertEqual(match.url, "https://a.example/x")
        XCTAssertEqual(match.range, NSRange(location: 3, length: 19))
        XCTAssertEqual((text as NSString).substring(with: match.range), "https://a.example/x")
    }

    func testSeveralAddressesInOneText() {
        let text = "https://a.example and https://b.example/x"
        let matches = LinkDetection.webAddresses(in: text)
        XCTAssertEqual(matches.map(\.url), ["https://a.example", "https://b.example/x"])
        XCTAssertEqual(matches.map { $0.range }, [NSRange(location: 0, length: 17), NSRange(location: 22, length: 19)])
    }

    func testLocationInsideTokenIsNil() {
        let text = "see https://a.example/x"
        XCTAssertNil(LinkDetection.webAddress(in: text, endingAt: 10))
        XCTAssertNil(LinkDetection.webAddress(in: text, endingAt: 4))
        XCTAssertNil(LinkDetection.webAddress(in: text, endingAt: 24))
        XCTAssertNil(LinkDetection.webAddress(in: text, endingAt: 0))
    }

    func testEmptyHostIsRejected() {
        XCTAssertTrue(LinkDetection.webAddresses(in: "https://").isEmpty)
        XCTAssertTrue(LinkDetection.webAddresses(in: "see https://.").isEmpty)
    }

    func testOverLongAddressIsRejected() {
        let base = "https://a.example/"
        let accepted = base + String(repeating: "x", count: 2048 - base.utf16.count)
        let rejected = base + String(repeating: "x", count: 2049 - base.utf16.count)
        XCTAssertEqual(LinkDetection.webAddresses(in: accepted).count, 1)
        XCTAssertTrue(LinkDetection.webAddresses(in: rejected).isEmpty)
    }

    func testSoleWebAddress() {
        XCTAssertEqual(LinkDetection.soleWebAddress("https://a.example/x"), "https://a.example/x")
        XCTAssertEqual(LinkDetection.soleWebAddress("  https://a.example/x  "), "https://a.example/x")
        XCTAssertEqual(LinkDetection.soleWebAddress("https://a.example/x."), "https://a.example/x.")
        XCTAssertEqual(LinkDetection.soleWebAddress("HTTP://a.example"), "HTTP://a.example")
    }

    func testSoleWebAddressRejectsAnythingElse() {
        XCTAssertNil(LinkDetection.soleWebAddress("(https://a.example/x)"))
        XCTAssertNil(LinkDetection.soleWebAddress("see https://a.example/x"))
        XCTAssertNil(LinkDetection.soleWebAddress(""))
        XCTAssertNil(LinkDetection.soleWebAddress("ftp://a.example"))
        XCTAssertNil(LinkDetection.soleWebAddress("https://"))
        XCTAssertNil(LinkDetection.soleWebAddress("https://a.example https://b.example"))
    }
}
