import XCTest
@testable import NevermoreCore

final class MarkdownShortcutTests: XCTestCase {
    // MARK: Block shortcuts

    func testQuoteMarker() throws {
        let match = try XCTUnwrap(MarkdownShortcut.block(in: "> ", caret: 2))
        XCTAssertEqual(match.block, .quote)
        XCTAssertEqual(match.markerRange, NSRange(location: 0, length: 2))
    }

    func testBulletMarkers() throws {
        for marker in ["- ", "* ", "+ "] {
            let match = try XCTUnwrap(MarkdownShortcut.block(in: marker, caret: 2), marker)
            XCTAssertEqual(match.block, .bulletedList, marker)
            XCTAssertEqual(match.markerRange, NSRange(location: 0, length: 2), marker)
        }
    }

    func testNumberedListMarkers() throws {
        let cases: [(marker: String, start: Int)] = [("1. ", 1), ("7) ", 7), ("007. ", 7), ("0. ", 0), ("99999. ", 99999)]
        for (marker, start) in cases {
            let match = try XCTUnwrap(MarkdownShortcut.block(in: marker, caret: marker.utf16.count), marker)
            XCTAssertEqual(match.block, .numberedList(start: start), marker)
            XCTAssertEqual(match.markerRange, NSRange(location: 0, length: marker.utf16.count), marker)
        }
    }

    func testNumberedListRejectsLongOrNonASCIIDigits() {
        XCTAssertNil(MarkdownShortcut.block(in: "123456. ", caret: 8))
        XCTAssertNil(MarkdownShortcut.block(in: "١. ", caret: 3))
    }

    func testMarkersRequireOnePlainSpace() {
        XCTAssertNil(MarkdownShortcut.block(in: ">  ", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: "1.  ", caret: 4))
        XCTAssertNil(MarkdownShortcut.block(in: "-\t", caret: 2))
        // A non-breaking space is not the marker's space. The caret sits at
        // the end of each string, where a real space would match.
        XCTAssertNil(MarkdownShortcut.block(in: "-\u{00A0}", caret: 2))
        XCTAssertNil(MarkdownShortcut.block(in: ">\u{00A0}", caret: 2))
        XCTAssertNil(MarkdownShortcut.block(in: "1.\u{00A0}", caret: 3))
    }

    func testMarkersRejectLeadingWhitespace() {
        XCTAssertNil(MarkdownShortcut.block(in: " > ", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: " - ", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: "\t1. ", caret: 4))
    }

    func testQuoteNeedsTrailingSpace() {
        XCTAssertNil(MarkdownShortcut.block(in: ">", caret: 1))
    }

    func testCodeBlockMarker() throws {
        let match = try XCTUnwrap(MarkdownShortcut.block(in: "```", caret: 3))
        XCTAssertEqual(match.block, .codeBlock)
        XCTAssertEqual(match.markerRange, NSRange(location: 0, length: 3))
    }

    func testCodeBlockNeedsAnEmptyParagraph() {
        XCTAssertNil(MarkdownShortcut.block(in: "```x", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: "``` x", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: "````", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: "````", caret: 4))
    }

    func testCodeBlockWithLineTerminator() throws {
        let match = try XCTUnwrap(MarkdownShortcut.block(in: "```\n", caret: 3))
        XCTAssertEqual(match.block, .codeBlock)
        XCTAssertEqual(match.markerRange, NSRange(location: 0, length: 3))
    }

    func testMarkersWorkInLaterParagraphs() throws {
        let match = try XCTUnwrap(MarkdownShortcut.block(in: "first\n> ", caret: 8))
        XCTAssertEqual(match.block, .quote)
        XCTAssertEqual(match.markerRange, NSRange(location: 6, length: 2))
    }

    func testMarkersWorkAfterEveryParagraphTerminator() throws {
        for (text, start) in [("first\r> ", 6), ("first\r\n> ", 7), ("first\u{2029}> ", 6)] {
            let match = try XCTUnwrap(MarkdownShortcut.block(in: text, caret: start + 2), text.debugDescription)
            XCTAssertEqual(match.block, .quote)
            XCTAssertEqual(match.markerRange, NSRange(location: start, length: 2))
        }
    }

    func testMarkersWorkInLastParagraphWithoutNewline() throws {
        let match = try XCTUnwrap(MarkdownShortcut.block(in: "first\n- ", caret: 8))
        XCTAssertEqual(match.block, .bulletedList)
        XCTAssertEqual(match.markerRange, NSRange(location: 6, length: 2))
    }

    func testMarkersBeforeExistingText() throws {
        let quote = try XCTUnwrap(MarkdownShortcut.block(in: "> hello", caret: 2))
        XCTAssertEqual(quote.block, .quote)
        let numbered = try XCTUnwrap(MarkdownShortcut.block(in: "1. hello", caret: 3))
        XCTAssertEqual(numbered.block, .numberedList(start: 1))
    }

    func testInvalidCaret() {
        XCTAssertNil(MarkdownShortcut.block(in: "> ", caret: 0))
        XCTAssertNil(MarkdownShortcut.block(in: "> ", caret: 3))
    }

    // MARK: Inline shortcuts

    func testBold() throws {
        let text = "**bold**"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 8))
        XCTAssertEqual(match.style, .bold)
        XCTAssertEqual(match.openRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(match.contentRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(match.closeRange, NSRange(location: 6, length: 2))
    }

    func testBoldNeedsBothStars() {
        XCTAssertNil(MarkdownShortcut.inline(in: "**bold*", caret: 7))
    }

    func testItalicDelimiters() throws {
        for (text, content) in [("*italic*", "italic"), ("_italic_", "italic")] {
            let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: text.utf16.count), text)
            XCTAssertEqual(match.style, .italic, text)
            XCTAssertEqual((text as NSString).substring(with: match.contentRange), content, text)
        }
    }

    func testBoldUnderscoreDelimiters() throws {
        let text = "__bold__"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 8))
        XCTAssertEqual(match.style, .bold)
        XCTAssertEqual((text as NSString).substring(with: match.contentRange), "bold")
    }

    func testDelimiterAfterSpace() throws {
        let text = "say **hi**"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 10))
        XCTAssertEqual(match.style, .bold)
        XCTAssertEqual(match.openRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(match.contentRange, NSRange(location: 6, length: 2))
        XCTAssertEqual(match.closeRange, NSRange(location: 8, length: 2))
    }

    func testDelimiterAfterBracket() throws {
        let text = "(*hi*"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 5))
        XCTAssertEqual(match.style, .italic)
        XCTAssertEqual(match.openRange, NSRange(location: 1, length: 1))
        XCTAssertEqual(match.contentRange, NSRange(location: 2, length: 2))
    }

    func testCodeSpan() throws {
        let text = "`code`"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 6))
        XCTAssertEqual(match.style, .code)
        XCTAssertEqual((text as NSString).substring(with: match.contentRange), "code")
    }

    func testCodeSpanNeedsNoBoundary() throws {
        let text = "a`b`"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 4))
        XCTAssertEqual(match.style, .code)
    }

    func testEmptyCodeSpanIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "```", caret: 3))
    }

    func testStrikethrough() throws {
        let text = "~~gone~~"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: text.utf16.count))
        XCTAssertEqual(match.style, .strikethrough)
        XCTAssertEqual((text as NSString).substring(with: match.contentRange), "gone")
    }

    func testSpoiler() throws {
        let text = "||secret||"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: text.utf16.count))
        XCTAssertEqual(match.style, .spoiler)
        XCTAssertEqual((text as NSString).substring(with: match.contentRange), "secret")
    }

    func testSpacedContentIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "2 * 3 *", caret: 7))
    }

    func testWordCharacterBeforeOpenerIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "a*b*", caret: 4))
    }

    func testSnakeCaseIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "snake_case_", caret: 11))
    }

    func testTripleAsteriskIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "***x***", caret: 7))
    }

    func testWhitespaceAfterOpenerIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "** x**", caret: 6))
    }

    func testWhitespaceBeforeCloserIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "**a **", caret: 6))
        XCTAssertNil(MarkdownShortcut.inline(in: "*a *", caret: 4))
        XCTAssertNil(MarkdownShortcut.inline(in: "~~a ~~", caret: 6))
        XCTAssertNil(MarkdownShortcut.inline(in: "||a ||", caret: 6))
    }

    func testLineBreakInContentIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "*a\nb*", caret: 5))
    }

    func testSecondParagraphRanges() throws {
        let text = "first\n**two**"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 13))
        XCTAssertEqual(match.style, .bold)
        XCTAssertEqual(match.openRange, NSRange(location: 6, length: 2))
        XCTAssertEqual(match.contentRange, NSRange(location: 8, length: 3))
        XCTAssertEqual(match.closeRange, NSRange(location: 11, length: 2))
    }

    func testLastMatchWins() throws {
        let text = "**a** **b**"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 11))
        XCTAssertEqual(match.style, .bold)
        XCTAssertEqual(match.openRange, NSRange(location: 6, length: 2))
        XCTAssertEqual(match.contentRange, NSRange(location: 8, length: 1))
        XCTAssertEqual(match.closeRange, NSRange(location: 9, length: 2))
    }

    func testEmojiUTF16Ranges() throws {
        let text = "🙂 *hi*"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 7))
        XCTAssertEqual(match.style, .italic)
        XCTAssertEqual(match.openRange, NSRange(location: 3, length: 1))
        XCTAssertEqual(match.contentRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(match.closeRange, NSRange(location: 6, length: 1))
    }

    func testCodeAllowsSurroundingWhitespace() throws {
        let text = "` x `"
        let match = try XCTUnwrap(MarkdownShortcut.inline(in: text, caret: 5))
        XCTAssertEqual(match.style, .code)
        XCTAssertEqual((text as NSString).substring(with: match.contentRange), " x ")
    }

    func testWhitespaceOnlyCodeIsNil() {
        XCTAssertNil(MarkdownShortcut.inline(in: "`  `", caret: 4))
    }

    func testInlineInvalidCaret() {
        XCTAssertNil(MarkdownShortcut.inline(in: "*a*", caret: 0))
        XCTAssertNil(MarkdownShortcut.inline(in: "*a*", caret: 4))
    }

    func testInlineContentMayNotSpanASoftLineBreak() {
        for separator in ["\u{2028}", "\u{0085}", "\u{000B}", "\u{000C}"] {
            XCTAssertNil(MarkdownShortcut.inline(in: "*a\(separator)b*", caret: 5), "U+\(String(separator.unicodeScalars.first!.value, radix: 16))")
        }
    }

    func testCodeFenceMustBeAloneInItsParagraph() {
        XCTAssertNil(MarkdownShortcut.block(in: "```\u{2028}", caret: 3))
        XCTAssertNil(MarkdownShortcut.block(in: "```\u{000B}", caret: 3))
        XCTAssertEqual(MarkdownShortcut.block(in: "```\n", caret: 3)?.block, .codeBlock)
        XCTAssertEqual(MarkdownShortcut.block(in: "```\u{2029}next", caret: 3)?.block, .codeBlock)
    }
}
