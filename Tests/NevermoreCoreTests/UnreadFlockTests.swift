import XCTest
import RavenProtocol
@testable import NevermoreCore

final class UnreadFlockTests: XCTestCase {
    private func channel(_ id: String, muted: Bool = false, archived: Bool = false) -> RavenChannel {
        RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id), "muted": .bool(muted), "is_archived": .bool(archived)]))
    }
    private func unread(_ counts: [(String, Double)]) -> JSONValue {
        .array(counts.map { .object(["name": .string($0.0), "unread_count": .number($0.1)]) })
    }

    func testOnlyUnmutedLiveConversationsGetABird() {
        let channels = [channel("a"), channel("b", muted: true), channel("c", archived: true), channel("d")]
        let perching = UnreadFlock.perching(channels: channels, unread: unread([("a", 3), ("b", 2), ("c", 1), ("d", 0), ("gone", 4)]))
        XCTAssertEqual(perching, ["a": 3])
    }

    func testCountsAreBoundedAndMalformedRowsAreSkipped() {
        let channels = [channel("a"), channel("b"), channel("c")]
        let rows: JSONValue = .array([
            .object(["name": .string("a"), "unread_count": .number(1e9)]),
            .object(["name": .string("b"), "unread_count": .string("3")]),
            .object(["name": .string("c"), "unread_count": .number(.nan)])
        ])
        XCTAssertEqual(UnreadFlock.perching(channels: channels, unread: rows), ["a": 9999])
        XCTAssertEqual(UnreadFlock.perching(channels: channels, unread: .null), [:])
    }

    func testChangesNameArrivalsGrowthAndDepartures() {
        let changes = UnreadFlock.changes(from: ["a": 1, "b": 2, "c": 5], to: ["b": 4, "c": 3, "d": 1])
        XCTAssertEqual(changes, [.left("a"), .grew("b"), .arrived("d")])
    }

    func testNoChangeMeansNoMovement() {
        XCTAssertEqual(UnreadFlock.changes(from: ["a": 2], to: ["a": 2]), [])
        XCTAssertEqual(UnreadFlock.changes(from: [:], to: [:]), [])
    }

    func testClearedOnlyWhenTheLastBirdLeaves() {
        XCTAssertTrue(UnreadFlock.cleared(from: ["a": 1], to: [:]))
        XCTAssertFalse(UnreadFlock.cleared(from: ["a": 1, "b": 1], to: ["b": 1]))
        XCTAssertFalse(UnreadFlock.cleared(from: [:], to: [:]))
    }
}
