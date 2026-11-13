import XCTest
@testable import NevermoreCore

final class LinkPreviewParserTests: XCTestCase {
    private let defaultRequested = URL(string: "https://example.com/article")!
    private let defaultResolved = URL(string: "https://example.com/article")!

    private func preview(
        _ html: String,
        charset: String? = nil,
        requested: URL? = nil,
        resolved: URL? = nil
    ) -> LinkPreview? {
        LinkPreviewParser.preview(
            html: html.data(using: .utf8)!,
            charset: charset,
            requested: requested ?? defaultRequested,
            final: resolved ?? defaultResolved
        )
    }

    func testOpenGraphPage() {
        let html = """
        <html><head>
        <meta property="og:title" content="Open Graph Title">
        <meta property="og:description" content="An Open Graph description.">
        <meta property="og:site_name" content="Example News">
        <meta property="og:image" content="https://cdn.example.com/cover.png">
        <title>Fallback Title</title>
        </head><body><p>Body</p></body></html>
        """
        let result = preview(html)
        XCTAssertEqual(result?.url, defaultRequested)
        XCTAssertEqual(result?.title, "Open Graph Title")
        XCTAssertEqual(result?.summary, "An Open Graph description.")
        XCTAssertEqual(result?.siteName, "Example News")
        XCTAssertEqual(result?.imageURL, URL(string: "https://cdn.example.com/cover.png"))
    }

    func testTwitterCardOnlyPage() {
        let html = """
        <html><head>
        <meta name="twitter:title" content="Twitter Title">
        <meta name="twitter:description" content="Twitter description.">
        <meta name="twitter:image" content="https://cdn.example.com/t.png">
        </head></html>
        """
        let result = preview(html)
        XCTAssertEqual(result?.title, "Twitter Title")
        XCTAssertEqual(result?.summary, "Twitter description.")
        XCTAssertEqual(result?.imageURL, URL(string: "https://cdn.example.com/t.png"))
    }

    func testTitleOnlyPage() {
        let html = "<html><head><title>Plain Title</title></head><body></body></html>"
        let result = preview(html)
        XCTAssertEqual(result?.title, "Plain Title")
        XCTAssertEqual(result?.summary, "")
        XCTAssertEqual(result?.siteName, "example.com")
        XCTAssertNil(result?.imageURL)
    }

    func testNoTitleGivesNil() {
        let html = "<html><head><meta property=\"og:description\" content=\"d\"></head></html>"
        XCTAssertNil(preview(html))
    }

    func testRelativeAndProtocolRelativeImagesResolveAgainstFinal() {
        let pathHTML = """
        <html><head>
        <meta property="og:title" content="T">
        <meta property="og:image" content="/img/cover.png">
        </head></html>
        """
        let pathResult = preview(pathHTML, resolved: URL(string: "https://cdn.example.com/page")!)
        XCTAssertEqual(pathResult?.imageURL, URL(string: "https://cdn.example.com/img/cover.png"))

        let protocolRelativeHTML = """
        <html><head>
        <meta property="og:title" content="T">
        <meta property="og:image" content="//cdn.example.com/cover.png">
        </head></html>
        """
        let protocolResult = preview(protocolRelativeHTML, resolved: URL(string: "https://example.com/page")!)
        XCTAssertEqual(protocolResult?.imageURL, URL(string: "https://cdn.example.com/cover.png"))
    }

    func testIneligibleImagesAreDropped() {
        let html = """
        <html><head>
        <meta property="og:title" content="T">
        <meta property="og:image" content="http://cdn.example.com/cover.png">
        <meta property="og:image" content="https://192.168.1.5/cover.png">
        <meta property="og:image" content="https://intranet.local/cover.png">
        <meta property="og:image" content="https://user:pass@cdn.example.com/leak.png">
        <meta property="og:image" content="https://cdn.example.com/ok.png">
        </head></html>
        """
        let result = preview(html)
        XCTAssertEqual(result?.imageURL, URL(string: "https://cdn.example.com/ok.png"))

        let allBadHTML = """
        <html><head>
        <meta property="og:title" content="T">
        <meta property="og:image" content="http://cdn.example.com/cover.png">
        </head></html>
        """
        XCTAssertNil(preview(allBadHTML)?.imageURL)
    }

    func testWhitespaceAndInvisibleCharactersAreCleaned() {
        let title = "  A\u{200B} B\tC\nD  "
        let summary = "Line\u{202E}One\u{202C}End\u{2060}\u{FEFF}\u{200E}"
        let html = "<html><head><meta property=\"og:title\" content=\"\(title)\"><meta property=\"og:description\" content=\"\(summary)\"></head></html>"
        let result = preview(html)
        XCTAssertEqual(result?.title, "A B C D")
        XCTAssertEqual(result?.summary, "LineOneEnd")
    }

    func testEveryBidirectionalControlIsRemoved() {
        let html = "<html><head><meta property=\"og:title\" content=\"Bank\u{061C}safe\u{2065}\u{206F}\u{2067}x\u{2069}\"></head></html>"
        XCTAssertEqual(preview(html)?.title, "Banksafex")
    }

    func testSoftHyphensGoAndJoinersStay() {
        let html = "<html><head><meta property=\"og:title\" content=\"Pay\u{00AD}Pal \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\"></head></html>"
        XCTAssertEqual(preview(html)?.title, "PayPal \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")
    }

    func testTruncationAddsEllipsis() {
        let longTitle = String(repeating: "x", count: LinkPreviewPolicy.maximumTitleLength + 50)
        let longSummary = String(repeating: "y", count: LinkPreviewPolicy.maximumSummaryLength + 50)
        let html = "<html><head><meta property=\"og:title\" content=\"\(longTitle)\"><meta property=\"og:description\" content=\"\(longSummary)\"></head></html>"
        let result = preview(html)
        XCTAssertEqual(result?.title.count, LinkPreviewPolicy.maximumTitleLength)
        XCTAssertTrue(result?.title.hasSuffix("…") ?? false)
        XCTAssertEqual(result?.summary.count, LinkPreviewPolicy.maximumSummaryLength)
        XCTAssertTrue(result?.summary.hasSuffix("…") ?? false)
    }

    func testNameAttributeVariantIsAccepted() {
        let html = """
        <html><head>
        <meta name="og:title" content="Named OG Title">
        <meta name="og:description" content="Named description.">
        <meta name="og:site_name" content="Named Site">
        </head></html>
        """
        let result = preview(html)
        XCTAssertEqual(result?.title, "Named OG Title")
        XCTAssertEqual(result?.summary, "Named description.")
        XCTAssertEqual(result?.siteName, "Named Site")
    }

    func testMetaKeysMatchCaseInsensitively() {
        let html = """
        <html><head>
        <meta property="OG:TITLE" content="Upper Title">
        </head></html>
        """
        XCTAssertEqual(preview(html)?.title, "Upper Title")
    }

    func testCharsetArgumentIsUsed() {
        let html = "<html><head><meta property=\"og:title\" content=\"Café\"></head></html>"
        let data = html.data(using: .isoLatin1)!
        let result = LinkPreviewParser.preview(html: data, charset: "ISO-8859-1", requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testCharsetFromMetaDeclarationIsUsed() {
        let html = "<html><head><meta charset=\"ISO-8859-1\"><meta property=\"og:title\" content=\"Café\"></head></html>"
        let data = html.data(using: .isoLatin1)!
        let result = LinkPreviewParser.preview(html: data, charset: nil, requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testCharsetWordOutsideMetaTagIsNotADeclaration() {
        let html = "<html><head><title>charset=iso-8859-1</title><meta charset=\"utf-8\"><meta property=\"og:title\" content=\"Café\"></head></html>"
        let result = LinkPreviewParser.preview(html: Data(html.utf8), charset: nil, requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testCharsetInsideAnAddressIsNotADeclaration() {
        let html = "<html><head><meta property=\"og:image\" content=\"https://cdn.example.com/i.png?charset=iso-8859-1\"><meta property=\"og:title\" content=\"Café\"></head></html>"
        let result = LinkPreviewParser.preview(html: Data(html.utf8), charset: nil, requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testByteOrderMarkOutranksTheAnnouncedCharset() {
        let html = "<html><head><meta property=\"og:title\" content=\"Café\"></head></html>"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8)
        let result = LinkPreviewParser.preview(html: data, charset: "ISO-8859-1", requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testByteOrderMarkDecidesEvenWhenThePageIsCutInsideACharacter() {
        // The loader's size cap can end the data in the middle of a
        // character; the mark still says how to read the rest.
        let html = "<html><head><meta property=\"og:title\" content=\"Café\"></head><body>é"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8).dropLast()
        let result = LinkPreviewParser.preview(html: data, charset: "ISO-8859-1", requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testTruncationKeepsWholeCharacters() {
        let longTitle = String(repeating: "👩🏽‍💻", count: LinkPreviewPolicy.maximumTitleLength + 10)
        let html = "<html><head><meta property=\"og:title\" content=\"\(longTitle)\"></head></html>"
        let title = preview(html)?.title ?? ""
        XCTAssertEqual(title.count, LinkPreviewPolicy.maximumTitleLength)
        XCTAssertTrue(title.dropLast().allSatisfy { $0 == "👩🏽‍💻" })
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testCharsetFromHttpEquivDeclarationIsUsed() {
        let html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=ISO-8859-1\"><meta property=\"og:title\" content=\"Café\"></head></html>"
        let data = html.data(using: .isoLatin1)!
        let result = LinkPreviewParser.preview(html: data, charset: nil, requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Café")
    }

    func testMalformedHTMLDoesNotCrash() {
        let html = "<html><head><meta property=\"og:title\" content=\"Broken\"><body><div"
        let result = preview(html)
        XCTAssertEqual(result?.title, "Broken")
    }

    func testOversizedInputIsTruncatedAndStillParses() {
        let head = "<html><head><meta property=\"og:title\" content=\"Big Page\"><meta property=\"og:description\" content=\"Summary\"></head><body>"
        let padding = String(repeating: "x", count: LinkPreviewPolicy.maximumHTMLBytes + 100_000)
        let data = (head + padding + "</body></html>").data(using: .utf8)!
        XCTAssertGreaterThan(data.count, LinkPreviewPolicy.maximumHTMLBytes)
        let result = LinkPreviewParser.preview(html: data, charset: nil, requested: defaultRequested, final: defaultResolved)
        XCTAssertEqual(result?.title, "Big Page")
        XCTAssertEqual(result?.summary, "Summary")
    }
}
