import XCTest
@testable import NevermoreCore
import RavenProtocol
import GRDB

/// Taking a message back and claiming it for delivery must exclude each
/// other: whichever reaches the store first wins, and the other is told.
final class InkStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> AccountStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreInkStoreTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return try AccountStore(directory: directory)
    }

    private func accept(_ html: String, in store: AccountStore) async throws -> SendOperation {
        try await store.saveDraft(Draft(channelID: "general", html: html, replyTo: "m-1", attachments: [], caret: 0))
        return try await store.acceptDraft(channelID: "general")
    }

    func testTakeBackCancelsAnUnattemptedSendAndReturnsItsContent() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Posting at two.</p>", in: store)

        let taken = try await store.takeBack(id: operation.id)

        XCTAssertEqual(taken?.html, "<p>Posting at two.</p>")
        XCTAssertEqual(taken?.replyTo, "m-1")
        XCTAssertEqual(taken?.state, .cancelled)
        let remaining = try await store.operations()
        XCTAssertTrue(remaining.isEmpty)
        // A second request finds nothing to take.
        let again = try await store.takeBack(id: operation.id)
        XCTAssertNil(again)
    }

    func testTakeBackRefusesASendThatWasClaimedForDelivery() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Too late.</p>", in: store)
        let claimed = try await store.beginAttempt(id: operation.id)
        XCTAssertEqual(claimed?.state, .uploading)
        XCTAssertEqual(claimed?.attempts, 1)

        let taken = try await store.takeBack(id: operation.id)

        XCTAssertNil(taken)
        let stored = try await store.operations()
        XCTAssertEqual(stored.map(\.state), [.uploading])
    }

    func testDeliveryCannotClaimASendThatWasTakenBack() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Never mind.</p>", in: store)
        _ = try await store.takeBack(id: operation.id)

        let claimed = try await store.beginAttempt(id: operation.id)

        XCTAssertNil(claimed)
    }

    func testRetryableSendsCanBeClaimedButNotTakenBack() async throws {
        let store = try makeStore()
        var operation = try await accept("<p>Second try.</p>", in: store)
        let first = try await store.beginAttempt(id: operation.id)
        operation = try XCTUnwrap(first)
        operation.state = .retryable
        try await store.updateOperation(operation)

        // The first attempt may have reached the server.
        let taken = try await store.takeBack(id: operation.id)
        XCTAssertNil(taken)
        let claimed = try await store.beginAttempt(id: operation.id)
        XCTAssertEqual(claimed?.attempts, 2)
        XCTAssertEqual(claimed?.state, .uploading)
    }

    func testReviewCannotReviveASendThatWasTakenBack() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Never mind.</p>", in: store)
        _ = try await store.takeBack(id: operation.id)

        // A flush that listed the send before the take back.
        let parked = try await store.sendToReview(id: operation.id, reason: "Older than a day")

        XCTAssertFalse(parked)
        let remaining = try await store.operations()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReviewParksAWaitingSendWithItsReason() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Old news.</p>", in: store)

        let parked = try await store.sendToReview(id: operation.id, reason: "Older than a day")

        XCTAssertTrue(parked)
        let stored = try await store.operations()
        XCTAssertEqual(stored.map(\.state), [.needsReview])
        XCTAssertEqual(stored.first?.error, "Older than a day")
        // Parked sends are not taken back from the transcript.
        let taken = try await store.takeBack(id: operation.id)
        XCTAssertNil(taken)
    }

    func testFailedPreflightCannotReviveATakenBackSend() async throws {
        let store = try makeStore()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreInkAttachment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("attachment".utf8).write(to: source)
        let attachment = try await store.stage(file: source)
        try await store.saveDraft(Draft(channelID: "general", html: "<p>Never mind.</p>", attachments: [attachment]))
        let operation = try await store.acceptDraft(channelID: "general")

        // flush lists this copy, then awaits attachment preflight before
        // beginAttempt. Undo wins while that preflight is suspended.
        var stale = operation
        let taken = try await store.takeBack(id: operation.id)
        XCTAssertEqual(taken?.state, .cancelled)
        stale.state = .retryable
        stale.error = "Preflight network failure"
        for state in [SendState.retryable, .needsReview, .rejected] {
            stale.state = state
            let updated = try await store.updateOperation(stale)
            XCTAssertFalse(updated)
            let remaining = try await store.operations()
            XCTAssertTrue(remaining.isEmpty, "A preflight failure revived a cancelled send: \(remaining.map(\.state))")
        }
    }

    func testStaleFailureCannotReviveAnAcknowledgedSend() async throws {
        let store = try makeStore()
        var stale = try await accept("<p>Delivered.</p>", in: store)
        let message = RavenMessage(raw: .object(["name": .string("delivered"), "channel_id": .string("general"), "text": .string(stale.html)]))
        try await store.acknowledge(id: stale.id, messages: [message])
        stale.state = .retryable
        let updated = try await store.updateOperation(stale)
        XCTAssertFalse(updated)
        let pending = try await store.operations()
        XCTAssertTrue(pending.isEmpty)
    }

    func testTakeBackRestoresTheFullDraftAtomically() async throws {
        let store = try makeStore()
        let directory = try XCTUnwrap(directories.last)
        let source = directory.appendingPathComponent("fixture.txt")
        try Data("attachment".utf8).write(to: source)
        let attachment = try await store.stage(file: source)
        let original = Draft(channelID: "general", html: "<p>Posting at two.</p>", replyTo: "m-1", attachments: [attachment])
        try await store.saveDraft(original)
        let operation = try await store.acceptDraft(channelID: "general")
        let empty = Draft(channelID: "general", html: "<p> </p>")
        try await store.saveDraft(empty)
        let other = Draft(channelID: "other", html: "<p>Unrelated work.</p>")
        try await store.saveDraft(other)

        let result = try await store.takeBack(id: operation.id, channelID: "general", replacingDraft: empty)

        var cancelled = operation; cancelled.state = .cancelled
        XCTAssertEqual(result, .restored(cancelled))
        let restored = try await store.draft(channelID: "general")
        var expected = original; expected.caret = Int.max
        XCTAssertEqual(restored, expected)
        let untouched = try await store.draft(channelID: "other")
        XCTAssertEqual(untouched, other)
        let pending = try await store.operations()
        XCTAssertTrue(pending.isEmpty)
        try await store.pruneStaging()
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.localPath))
    }

    func testTakeBackRejectsEveryNewerDraftWithoutCancelling() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Original.</p>", in: store)
        let source = try XCTUnwrap(directories.last).appendingPathComponent("newer.txt")
        try Data("newer attachment".utf8).write(to: source)
        let attachment = try await store.stage(file: source)
        let newerDrafts = [
            Draft(channelID: "general", html: "<p>Newer text.</p>"),
            Draft(channelID: "general", replyTo: "newer-reply"),
            Draft(channelID: "general", attachments: [attachment])
        ]
        for newer in newerDrafts {
            try await store.saveDraft(newer)
            // The caller read no draft before a different window saved one.
            let result = try await store.takeBack(id: operation.id, channelID: "general", replacingDraft: nil)
            XCTAssertEqual(result, .draftChanged)
            // Passing the newer snapshot itself must not authorize its loss.
            let nonempty = try await store.takeBack(id: operation.id, channelID: "general", replacingDraft: newer)
            XCTAssertEqual(nonempty, .draftChanged)
            let current = try await store.draft(channelID: "general")
            XCTAssertEqual(current, newer)
            let pending = try await store.operations()
            XCTAssertEqual(pending, [operation])
        }
    }

    func testTakeBackRejectsAChangedEmptyDraftSnapshot() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Original.</p>", in: store)
        let before = Draft(channelID: "general")
        try await store.saveDraft(before)
        let after = Draft(channelID: "general", html: "<p>New work.</p>")
        try await store.saveDraft(after)

        let result = try await store.takeBack(id: operation.id, channelID: "general", replacingDraft: before)

        XCTAssertEqual(result, .draftChanged)
        let pending = try await store.operations()
        XCTAssertEqual(pending, [operation])
        let current = try await store.draft(channelID: "general")
        XCTAssertEqual(current, after)
    }

    func testTakeBackRejectsTheWrongConversationOrADeliveryClaim() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Original.</p>", in: store)
        let wrong = try await store.takeBack(id: operation.id, channelID: "other", replacingDraft: nil)
        XCTAssertEqual(wrong, .unavailable)
        _ = try await store.beginAttempt(id: operation.id)
        let claimed = try await store.takeBack(id: operation.id, channelID: "general", replacingDraft: nil)
        XCTAssertEqual(claimed, .unavailable)
        let pending = try await store.operations()
        XCTAssertEqual(pending.map(\.state), [.uploading])
        let draft = try await store.draft(channelID: "general")
        XCTAssertNil(draft)
    }

    func testFailedDraftRestorationDoesNotCancelTheSend() async throws {
        let store = try makeStore()
        let operation = try await accept("<p>Keep recoverable.</p>", in: store)
        let directory = try XCTUnwrap(directories.last)
        let database = try DatabaseQueue(path: directory.appendingPathComponent(AccountStore.databaseFileName).path)
        try await database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_draft_restore BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END")
        }
        do {
            _ = try await store.takeBack(id: operation.id, channelID: "general", replacingDraft: nil)
            XCTFail("Expected the draft write to fail")
        } catch { XCTAssertTrue(error is DatabaseError) }
        let pending = try await store.operations()
        XCTAssertEqual(pending, [operation])
        let draft = try await store.draft(channelID: "general")
        XCTAssertNil(draft)
    }

    func testUnknownSendsAreNeitherTakenNorClaimed() async throws {
        let store = try makeStore()
        let taken = try await store.takeBack(id: UUID())
        let claimed = try await store.beginAttempt(id: UUID())
        XCTAssertNil(taken)
        XCTAssertNil(claimed)
    }
}
