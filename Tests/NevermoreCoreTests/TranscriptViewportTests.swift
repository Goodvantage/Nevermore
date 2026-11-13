import Foundation
import Testing
@testable import NevermoreCore

struct TranscriptViewportTests {
    /// A 600 pt pane with a 52 pt toolbar and a 70 pt composer over it.
    private let pane = TranscriptViewport(clipHeight: 600, topInset: 52, bottomInset: 70, wrapWidth: 700)

    @Test func theReadableBandEndsAboveTheComposer() {
        #expect(pane.readableBottom(atOrigin: 1000) == 1530)
        #expect(TranscriptViewport(clipHeight: 600, wrapWidth: 700).readableBottom(atOrigin: 1000) == 1600)
    }

    @Test func scrollingRunsFromBelowTheToolbarToAboveTheComposer() {
        let range = pane.originRange(documentHeight: 3000)
        #expect(range.lowerBound == -52)
        // The last line rests on the readable band's bottom edge.
        #expect(pane.readableBottom(atOrigin: range.upperBound) == 3000)
    }

    @Test func aDocumentThatFitsHasOnePositionAtItsTop() {
        #expect(pane.originRange(documentHeight: 300) == -52 ... -52)
        #expect(pane.originRange(documentHeight: 0) == -52 ... -52)
    }

    @Test func onlyAVisibleChangeOfShapeMovesText() {
        var other = pane
        #expect(!other.differs(from: pane))
        // Less than the tolerance in a height or an inset moves no text.
        other.clipHeight += TranscriptViewport.tolerance / 2
        other.bottomInset -= TranscriptViewport.tolerance / 2
        #expect(!other.differs(from: pane))
        var shorter = pane, underToolbar = pane, typing = pane, narrower = pane
        shorter.clipHeight -= 40; underToolbar.topInset += 28; typing.bottomInset += 17; narrower.wrapWidth -= 1
        for changed in [shorter, underToolbar, typing, narrower] {
            #expect(changed.differs(from: pane))
            #expect(pane.differs(from: changed))
        }
    }

    @Test func anyChangeOfWidthCanMoveText() {
        // One word that no longer fits moves every line below it, so the
        // wrap width has no tolerance.
        var wider = pane
        wider.wrapWidth += TranscriptViewport.tolerance / 2
        #expect(wider.differs(from: pane))
        #expect(pane.differs(from: wider))
    }

    @Test func aLineKeepsItsGapWhenThePaneGetsShorter() {
        // The line ends at 1520, 10 pt above the band's edge at 1530.
        let anchor = TranscriptViewportAnchor(character: 4200, lineBottom: 1520, readableBottom: pane.readableBottom(atOrigin: 1000))
        #expect(anchor.gap == 10)
        var shorter = pane
        shorter.clipHeight = 400
        let origin = anchor.origin(lineBottom: 1520, in: shorter, documentHeight: 3000)
        #expect(origin == 1200)
        #expect(shorter.readableBottom(atOrigin: origin) - 1520 == anchor.gap)
    }

    @Test func aLineKeepsItsGapWhenReflowMovesIt() {
        let anchor = TranscriptViewportAnchor(character: 4200, gap: 10)
        var narrower = pane
        narrower.wrapWidth = 400
        // Narrower text is taller: the same line now ends at 2600 of 5000.
        let origin = anchor.origin(lineBottom: 2600, in: narrower, documentHeight: 5000)
        #expect(narrower.readableBottom(atOrigin: origin) - 2600 == 10)
    }

    @Test func aLineKeepsItsGapWhenTheComposerGrows() {
        let anchor = TranscriptViewportAnchor(character: 4200, gap: 10)
        var typing = pane
        typing.bottomInset = 150
        let origin = anchor.origin(lineBottom: 1520, in: typing, documentHeight: 3000)
        #expect(origin == 1080)
        #expect(typing.readableBottom(atOrigin: origin) - 1520 == 10)
    }

    @Test func aLineCutByTheBandEdgeStaysCut() {
        let anchor = TranscriptViewportAnchor(character: 0, lineBottom: 1536, readableBottom: 1530)
        #expect(anchor.gap == -6)
        // The same 6 pt stay below the edge of a shorter pane.
        var shorter = pane
        shorter.clipHeight = 400
        let origin = anchor.origin(lineBottom: 1536, in: shorter, documentHeight: 3000)
        #expect(shorter.readableBottom(atOrigin: origin) == 1530)
    }

    @Test func placementStopsAtTheEndsOfTheDocument() {
        // Near the top, a taller pane has nothing above to reveal.
        let early = TranscriptViewportAnchor(character: 12, gap: 10)
        var taller = pane
        taller.clipHeight = 1200
        #expect(early.origin(lineBottom: 500, in: taller, documentHeight: 3000) == -52)
        // A gap larger than the space below the line stops at the end.
        let late = TranscriptViewportAnchor(character: 9000, gap: 400)
        let origin = late.origin(lineBottom: 2900, in: pane, documentHeight: 3000)
        #expect(pane.readableBottom(atOrigin: origin) == 3000)
        // A document that fits stays at its top whatever the anchor says.
        #expect(late.origin(lineBottom: 200, in: pane, documentHeight: 300) == -52)
    }
}
