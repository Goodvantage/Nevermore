import XCTest
@testable import NevermoreCore

final class InkPlanTests: XCTestCase {
    private func words(_ text: String) -> [String] {
        InkFlightPlan.wordRanges(in: text).map { (text as NSString).substring(with: $0) }
    }

    func testWordRangesSplitOnAnyWhitespace() {
        XCTAssertEqual(words("  I can\tpost it.\nTen minutes\u{00A0}more "), ["I", "can", "post", "it.", "Ten", "minutes", "more"])
        XCTAssertEqual(words(""), [])
        XCTAssertEqual(words(" \n\t "), [])
    }

    func testWordRangesAreUTF16Ranges() {
        // An emoji is two UTF-16 units; ranges must index the NSString.
        let text = "ship it 🎉 now"
        let ranges = InkFlightPlan.wordRanges(in: text)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 4), NSRange(location: 5, length: 2), NSRange(location: 8, length: 2), NSRange(location: 11, length: 3)])
    }

    func testSameWordsPairUpAcrossDifferentLineBreaks() {
        let plan = InkFlightPlan.plan(source: "Posting at two.", destination: "Posting\nat  two.")
        guard case .words(let pairs) = plan else { return XCTFail("expected a word plan") }
        XCTAssertEqual(pairs.map(\.source), [NSRange(location: 0, length: 7), NSRange(location: 8, length: 2), NSRange(location: 11, length: 4)])
        XCTAssertEqual(pairs.map(\.destination), [NSRange(location: 0, length: 7), NSRange(location: 8, length: 2), NSRange(location: 12, length: 4)])
    }

    func testDifferentWordsFlyAsABlock() {
        // The transcript adds list markers the composer does not show.
        XCTAssertEqual(InkFlightPlan.plan(source: "milk eggs", destination: "• milk • eggs"), .block)
        XCTAssertEqual(InkFlightPlan.plan(source: "milk eggs", destination: "milk egg"), .block)
        XCTAssertEqual(InkFlightPlan.plan(source: "", destination: ""), .block)
    }

    func testLongMessagesFlyAsABlock() {
        let long = Array(repeating: "word", count: InkFlightPlan.wordLimit + 1).joined(separator: " ")
        XCTAssertEqual(InkFlightPlan.plan(source: long, destination: long), .block)
        let fits = Array(repeating: "word", count: InkFlightPlan.wordLimit).joined(separator: " ")
        guard case .words(let pairs) = InkFlightPlan.plan(source: fits, destination: fits) else { return XCTFail("expected a word plan") }
        XCTAssertEqual(pairs.count, InkFlightPlan.wordLimit)
    }

    func testDraftRestorationAcceptsOnlyAnEmptyReadableDraft() {
        XCTAssertTrue(InkRules.canRestoreDraft(nil))
        XCTAssertTrue(InkRules.canRestoreDraft(Draft(channelID: "general")))
        XCTAssertTrue(InkRules.canRestoreDraft(Draft(channelID: "general", html: "<p> \n </p>")))
        XCTAssertFalse(InkRules.canRestoreDraft(Draft(channelID: "general", html: "<p>Newer text.</p>")))
        XCTAssertFalse(InkRules.canRestoreDraft(Draft(channelID: "general", replyTo: "new-reply")))
        let attachment = StagedAttachment(localPath: "/fixture/file", filename: "file")
        XCTAssertFalse(InkRules.canRestoreDraft(Draft(channelID: "general", attachments: [attachment])))
    }

    func testWetnessFollowsTheOutboxState() {
        XCTAssertEqual(InkWetness(.queued), .flowing)
        XCTAssertEqual(InkWetness(.uploading), .flowing)
        XCTAssertEqual(InkWetness(.sending), .flowing)
        XCTAssertEqual(InkWetness(.retryable), .stalled)
        XCTAssertEqual(InkWetness(.needsReview), .blocked)
        XCTAssertEqual(InkWetness(.rejected), .blocked)
        XCTAssertNil(InkWetness(.acknowledged))
        XCTAssertNil(InkWetness(.cancelled))
    }
}
