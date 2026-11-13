import XCTest
@testable import NevermoreCore

final class StickerRulesTests: XCTestCase {
    func testASmallMovementStaysAClick() {
        XCTAssertFalse(StickerRules.isDrag(from: .zero, to: CGPoint(x: 4, y: 4)))
        XCTAssertTrue(StickerRules.isDrag(from: .zero, to: CGPoint(x: 6, y: 0)))
        XCTAssertTrue(StickerRules.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 5, y: 5)))
    }

    func testTiltLeansAgainstTheDragAndIsBounded() {
        XCTAssertEqual(StickerRules.tilt(horizontalVelocity: 0), 0)
        XCTAssertEqual(StickerRules.tilt(horizontalVelocity: 700), StickerRules.maximumTilt / 2, accuracy: 1e-9)
        XCTAssertEqual(StickerRules.tilt(horizontalVelocity: 9000), StickerRules.maximumTilt)
        XCTAssertEqual(StickerRules.tilt(horizontalVelocity: -9000), -StickerRules.maximumTilt)
        XCTAssertEqual(StickerRules.tilt(horizontalVelocity: .nan), 0)
    }

    func testASlowReleaseIsNotAThrow() {
        XCTAssertNil(StickerRules.rest(from: .zero, velocity: CGVector(dx: 600, dy: 600)))
        XCTAssertNil(StickerRules.rest(from: .zero, velocity: CGVector(dx: CGFloat.infinity, dy: 0)))
    }

    func testAThrowTravelsAlongItsVelocity() throws {
        let rest = try XCTUnwrap(StickerRules.rest(from: CGPoint(x: 100, y: 100), velocity: CGVector(dx: 0, dy: 1000)))
        XCTAssertEqual(rest.x, 100, accuracy: 1e-9)
        XCTAssertEqual(rest.y, 100 + 1000 * StickerRules.flingGlide, accuracy: 1e-9)
    }

    func testAWildThrowIsCapped() throws {
        let rest = try XCTUnwrap(StickerRules.rest(from: .zero, velocity: CGVector(dx: -30_000, dy: 0)))
        XCTAssertEqual(rest.x, -StickerRules.flingReach, accuracy: 1e-9)
    }

    func testGlideStartsFastAndEndsAtRest() {
        let start = CGPoint.zero, rest = CGPoint(x: 100, y: 0)
        XCTAssertEqual(StickerRules.glide(from: start, to: rest, progress: 0).x, 0)
        XCTAssertGreaterThan(StickerRules.glide(from: start, to: rest, progress: 0.5).x, 80)
        XCTAssertEqual(StickerRules.glide(from: start, to: rest, progress: 1).x, 100)
        XCTAssertEqual(StickerRules.glide(from: start, to: rest, progress: 7).x, 100)
    }

    func testChipChangesAreNamed() {
        let old = [ReactionChip(label: "👍", count: 2, includesCurrentUser: false), ReactionChip(label: "🎉", count: 1, includesCurrentUser: true), ReactionChip(label: "👀", count: 1, includesCurrentUser: false)]
        let new = [ReactionChip(label: "👍", count: 3, includesCurrentUser: true), ReactionChip(label: "👀", count: 1, includesCurrentUser: false), ReactionChip(label: "🔥", count: 1, includesCurrentUser: false)]
        XCTAssertEqual(StickerRules.changes(from: old, to: new), [
            .counted(label: "👍", from: 2, to: 3),
            .added(label: "🔥", count: 1, mine: false),
            .removed(label: "🎉")
        ])
        XCTAssertEqual(StickerRules.changes(from: new, to: new), [])
    }
}
