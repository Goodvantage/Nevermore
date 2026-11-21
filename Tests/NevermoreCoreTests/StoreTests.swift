import XCTest
@testable import NevermoreCore
import RavenProtocol
import GRDB

final class StoreTests: XCTestCase {
    private var tempPaths: [URL] = []

    override func tearDown() {
        for url in tempPaths { try? FileManager.default.removeItem(at: url) }
        tempPaths.removeAll()
        super.tearDown()
    }

    func testExactMessageLookupRespectsChannelAndDeletion() async throws {
        let store = try AccountStore(directory: track(makeStoreDirectory()))
        let row = makeMessage(id: "message", channel: "first", creation: creation(1), text: "<p>Cached</p>")
        try await store.cacheMessages([row])

        let found = try await store.message(id: row.id, channelID: "first")
        let otherChannel = try await store.message(id: row.id, channelID: "second")
        XCTAssertEqual(found?.raw, row.raw)
        XCTAssertNil(otherChannel)

        try await store.deleteMessages(ids: [row.id])
        let deleted = try await store.message(id: row.id, channelID: "first")
        XCTAssertNil(deleted)
    }

    // MARK: Helpers

    private func makeStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NevermoreStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func track(_ url: URL) -> URL { tempPaths.append(url); return url }

    private func makeSourceFile(contents: String) throws -> URL {
        let url = track(FileManager.default.temporaryDirectory
            .appendingPathComponent("NevermoreStoreTests-src-\(UUID().uuidString)"))
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeMessage(id: String, channel: String, creation: String, text: String,
                             owner: String = "alex@example.com", batch: String? = nil) -> RavenMessage {
        var fields: [String: JSONValue] = [
            "name": .string(id),
            "channel_id": .string(channel),
            "creation": .string(creation),
            "text": .string(text),
            "owner": .string(owner),
            "message_type": .string("Text"),
        ]
        if let batch { fields["message_batch_id"] = .string(batch) }
        return RavenMessage(raw: .object(fields))
    }

    private func makeChannel(id: String, title: String) -> RavenChannel {
        RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(title), "workspace": .string("ws")]))
    }

    private func creation(_ i: Int) -> String {
        "2026-01-01 00:00:\(String(format: "%06d", i)).000000"
    }

    /// Runs an async throwing expression and returns the error it threw, if any.
    private func captureError<T>(_ body: () async throws -> T) async -> Error? {
        do { _ = try await body(); return nil } catch { return error }
    }

    /// Simulates an app restart: the previous store must be released (its lock
    /// dropped) before the same directory can be opened again.
    private func reopen(directory: URL) throws -> AccountStore {
        var lastError: Error = StoreError.lockFailed(directory)
        for _ in 0..<100 {
            do { return try AccountStore(directory: directory) }
            catch let error as StoreError {
                if case .directoryInUse = error { lastError = error; Thread.sleep(forTimeInterval: 0.02); continue }
                throw error
            }
        }
        throw lastError
    }

    private func openDB(_ directory: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: directory.appendingPathComponent(AccountStore.databaseFileName).path)
    }

    private func fetchStrings(_ q: DatabaseQueue, _ sql: String) async throws -> [String] {
        try await q.read { db in try String.fetchAll(db, sql: sql) }
    }

    private func fetchString(_ q: DatabaseQueue, _ sql: String, _ arguments: StatementArguments = []) async throws -> String? {
        try await q.read { db in try String.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func fetchInt64(_ q: DatabaseQueue, _ sql: String) async throws -> Int64? {
        try await q.read { db in try Int64.fetchOne(db, sql: sql) }
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }

    // XCTest autoclosures cannot contain await, so async assertions go through
    // these helpers (a throwing expression simply compares as nil/false).
    private func XCTAssertEqualA<T: Equatable>(_ expression: @autoclosure () async throws -> T,
                                                _ expected: @autoclosure () throws -> T,
                                                file: StaticString = #filePath, line: UInt = #line) async {
        let value = try? await expression()
        XCTAssertEqual(value, try expected(), file: file, line: line)
    }

    private func XCTAssertTrueA(_ expression: @autoclosure () async throws -> Bool,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let value = try? await expression()
        XCTAssertEqual(value, true, file: file, line: line)
    }

    private func XCTAssertNilA(_ expression: @autoclosure () async throws -> Any?,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let value = try? await expression()
        XCTAssertNil(value, file: file, line: line)
    }

    // MARK: Migrations, locking, privacy permissions

    func testExplicitMigrationsAreAppliedAndIdempotentAcrossReopen() async throws {
        let dir = track(makeStoreDirectory())
        var store: AccountStore? = try AccountStore(directory: dir)
        try await store!.saveDraft(Draft(channelID: "c", html: "<p>keep</p>"))

        let q = try openDB(dir)
        let applied = try await fetchStrings(q, "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        XCTAssertEqual(applied, ["v1", "v2", "v3_review_legacy_gif_retries"])
        let fts = try await fetchString(q, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts'")
        XCTAssertEqual(fts, "messages_fts")

        store = nil
        let reopened = try reopen(directory: dir)
        let draft = try await reopened.draft(channelID: "c")
        XCTAssertEqual(draft?.html, "<p>keep</p>")
        // Re-running migrations on an up-to-date store is a no-op, not an error.
        let appliedAgain = try await fetchStrings(q, "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        XCTAssertEqual(appliedAgain, ["v1", "v2", "v3_review_legacy_gif_retries"])
    }

    func testUpgradeProtectsPreviouslyAttemptedGIFRetries() async throws {
        let directory = track(makeStoreDirectory())
        var store: AccountStore? = try AccountStore(directory: directory)
        let html = #"<p><img src="https://media.tenor.com/a/b.gif"></p>"#
        var previous = try await store!.acceptGIF(channelID: "c", html: html)
        previous.state = .retryable
        previous.attempts = 1
        try await store!.updateOperation(previous)
        var requeued = try await store!.acceptGIF(channelID: "c", html: html)
        // The previous Outbox's Retry action persisted queued and retained
        // the attempt count before starting the next flush.
        requeued.attempts = 1
        try await store!.updateOperation(requeued)
        let fresh = try await store!.acceptGIF(channelID: "c", html: html)
        let db = try openDB(directory)
        try await db.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3_review_legacy_gif_retries'") }
        store = nil

        let upgraded = try reopen(directory: directory)
        let rows = try await upgraded.operations()
        XCTAssertEqual(rows.first { $0.id == previous.id }?.state, .needsReview)
        XCTAssertEqual(rows.first { $0.id == requeued.id }?.state, .needsReview)
        XCTAssertEqual(rows.first { $0.id == fresh.id }?.state, .queued)
    }

    func testDirectoryIsExclusivelyAccountScopedWithUserOnlyPermissions() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        XCTAssertEqual(try posixPermissions(dir), 0o700)
        XCTAssertEqual(try posixPermissions(dir.appendingPathComponent(AccountStore.stagingDirectoryName)), 0o700)
        XCTAssertEqual(try posixPermissions(dir.appendingPathComponent(AccountStore.databaseFileName)), 0o600)
        let error = await captureError { try AccountStore(directory: dir) }
        XCTAssertEqual(error as? StoreError, .directoryInUse(dir))
        _ = store
    }

    // MARK: Drafts and transactional acceptance

    func testDraftRoundTrip() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        await XCTAssertNilA(try await store.draft(channelID: "c"))
        let draft = Draft(channelID: "c", html: "<p>hi</p>", replyTo: "m9", attachments: [], caret: 7)
        try await store.saveDraft(draft)
        await XCTAssertEqualA(try await store.draft(channelID: "c"), draft)
        try await store.saveDraft(Draft(channelID: "c", html: "<p>edited</p>", caret: 2))
        await XCTAssertEqualA(try await store.draft(channelID: "c"), Draft(channelID: "c", html: "<p>edited</p>", caret: 2))
    }

    func testAcceptDraftIsAtomicInsertPlusDelete() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.saveDraft(Draft(channelID: "c1", html: "one"))
        try await store.saveDraft(Draft(channelID: "c2", html: "two"))

        let op = try await store.acceptDraft(channelID: "c1")
        XCTAssertEqual(op.state, .queued)
        XCTAssertEqual(op.attempts, 0)
        XCTAssertNil(op.error)
        XCTAssertEqual(op.channelID, "c1")
        XCTAssertEqual(op.html, "one")

        // Both effects happened together: draft gone, operation queued.
        await XCTAssertNilA(try await store.draft(channelID: "c1"))
        let other = try await store.draft(channelID: "c2")
        XCTAssertEqual(other?.html, "two")
        let ops = try await store.operations()
        XCTAssertEqual(ops.map(\.id), [op.id])

        // Accepting again finds no draft and creates no second operation.
        let error = await captureError { try await store.acceptDraft(channelID: "c1") }
        XCTAssertEqual(error as? StoreError, .draftNotFound("c1"))
        await XCTAssertEqualA(try await store.operations().count, 1)
    }

    func testUpdateOperationForbidsPayloadAndIdChangesExceptStateAndUploadMetadata() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        let src = try makeSourceFile(contents: "attachment-bytes")
        let staged = try await store.stage(file: src)
        try await store.saveDraft(Draft(channelID: "c", html: "<p>a</p>", attachments: [staged]))
        let op = try await store.acceptDraft(channelID: "c")

        func tampered(_ mutate: (inout SendOperation) -> Void) async -> Error? {
            var copy = op
            mutate(&copy)
            return await captureError { try await store.updateOperation(copy) }
        }
        let err1 = await tampered { $0.html = "<p>b</p>" } as? StoreError
        XCTAssertEqual(err1, .immutableFieldChanged("payload"))
        let err2 = await tampered { $0.channelID = "other" } as? StoreError
        XCTAssertEqual(err2, .immutableFieldChanged("payload"))
        let err3 = await tampered { $0.replyTo = "m1" } as? StoreError
        XCTAssertEqual(err3, .immutableFieldChanged("payload"))
        let err4 = await tampered { $0.createdAt = $0.createdAt.addingTimeInterval(60) } as? StoreError
        XCTAssertEqual(err4, .immutableFieldChanged("payload"))
        let err5 = await tampered { $0.attachments = [] } as? StoreError
        XCTAssertEqual(err5, .immutableFieldChanged("attachments"))
        let err6 = await tampered { $0.attachments[0].id = UUID() } as? StoreError
        XCTAssertEqual(err6, .immutableFieldChanged("attachments"))
        let err7 = await tampered { $0.attachments[0].localPath = "/etc/passwd" } as? StoreError
        XCTAssertEqual(err7, .immutableFieldChanged("attachments"))
        let err8 = await tampered { $0.attachments[0].filename = "x" } as? StoreError
        XCTAssertEqual(err8, .immutableFieldChanged("attachments"))
        let ghostID = UUID()
        let err9 = await tampered { $0.id = ghostID } as? StoreError
        XCTAssertEqual(err9, .operationNotFound(ghostID))

        // The stored row survived every rejected mutation untouched.
        await XCTAssertEqualA(try await store.operations(), [op])

        // State, attempts, error and upload metadata are mutable.
        var allowed = op
        allowed.state = .uploading
        allowed.attempts = 3
        allowed.error = "network down"
        allowed.attachments[0].uploaded = .object(["file_url": .string("/private/files/x")])
        try await store.updateOperation(allowed)
        let fetched = try await store.operations()
        XCTAssertEqual(fetched, [allowed])
        XCTAssertEqual(fetched[0].html, "<p>a</p>")
        XCTAssertEqual(fetched[0].id, op.id)
    }

    // MARK: Acknowledgement atomicity

    func testAcknowledgeIsAtomicAndRetainsTerminalRow() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.saveDraft(Draft(channelID: "c", html: "send me"))
        let op = try await store.acceptDraft(channelID: "c")

        // Mismatched channel: nothing is written, the operation stays queued.
        let wrong = makeMessage(id: "w1", channel: "other", creation: creation(1), text: "<p>wrong-channel-word</p>", batch: op.id.uuidString)
        let wrongError = await captureError { try await store.acknowledge(id: op.id, messages: [wrong]) }
        guard case .invalidAcknowledgement = wrongError as? StoreError else { return XCTFail("unexpected error \(String(describing: wrongError))") }
        await XCTAssertEqualA(try await store.operations().map(\.id), [op.id])
        await XCTAssertTrueA((try await store.messages(channelID: "other")).isEmpty)
        await XCTAssertTrueA((try await store.search("wrong-channel-word")).isEmpty)

        // Empty acknowledgement is rejected.
        let emptyError = await captureError { try await store.acknowledge(id: op.id, messages: []) }
        XCTAssertNotNil(emptyError)

        // Batch mismatch is rejected.
        let badBatch = makeMessage(id: "b1", channel: "c", creation: creation(2), text: "<p>x</p>", batch: "not-the-op")
        let batchError = await captureError { try await store.acknowledge(id: op.id, messages: [badBatch]) }
        XCTAssertNotNil(batchError)
        await XCTAssertEqualA(try await store.operations().map(\.id), [op.id])

        // Valid acknowledgement: operation becomes terminal AND messages are cached.
        let rows = [
            makeMessage(id: "a1", channel: "c", creation: creation(3), text: "<p>ack-word here</p>", owner: "me@example.com", batch: op.id.uuidString),
            makeMessage(id: "a2", channel: "c", creation: creation(4), text: "<p>file caption</p>", owner: "me@example.com", batch: op.id.uuidString),
        ]
        try await store.acknowledge(id: op.id, messages: rows)
        await XCTAssertTrueA((try await store.operations()).isEmpty)
        await XCTAssertEqualA(try await store.messages(channelID: "c").map(\.id), ["a1", "a2"])
        await XCTAssertEqualA(try await store.search("ack-word").map(\.id), ["a1"])

        // Terminal operations are retained durably, not deleted.
        let q = try openDB(dir)
        let state = try await fetchString(q, "SELECT state FROM operations WHERE id = ?", [op.id.uuidString])
        XCTAssertEqual(state, "acknowledged")
    }

    // MARK: Interruption recovery and restart durability

    func testRecoverInterruptedOperationsAcrossRestart() async throws {
        let dir = track(makeStoreDirectory())
        let src = try makeSourceFile(contents: "payload")
        var store: AccountStore? = try AccountStore(directory: dir)
        let staged = try await store!.stage(file: src)
        try await store!.saveDraft(Draft(channelID: "c", html: "<p>one</p>", attachments: [staged]))
        let uploadingOp = try await store!.acceptDraft(channelID: "c")
        var uploading = uploadingOp
        uploading.state = .uploading
        uploading.attempts = 2
        uploading.attachments[0].uploaded = .string("/private/files/u")
        try await store!.updateOperation(uploading)

        try await store!.saveDraft(Draft(channelID: "c", html: "<p>two</p>"))
        let sendingOp = try await store!.acceptDraft(channelID: "c")
        var sending = sendingOp
        sending.state = .sending
        try await store!.updateOperation(sending)

        try await store!.saveDraft(Draft(channelID: "c", html: "<p>three</p>"))
        let queuedOp = try await store!.acceptDraft(channelID: "c")

        store = nil
        let reopened = try reopen(directory: dir)
        try await reopened.recoverInterruptedOperations()
        let ops = try await reopened.operations()
        XCTAssertEqual(ops.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: ops.map { ($0.id, $0) })
        // Interrupted in-flight states resume as retryable with the original
        // immutable payload, id, attempts and upload metadata.
        var expected = uploading
        expected.state = .retryable
        XCTAssertEqual(byID[uploadingOp.id], expected)
        XCTAssertEqual(byID[uploadingOp.id]?.state, .retryable)
        XCTAssertEqual(byID[uploadingOp.id]?.attachments[0].uploaded, .string("/private/files/u"))
        XCTAssertEqual(byID[sendingOp.id]?.state, .retryable)
        XCTAssertEqual(byID[sendingOp.id]?.html, "<p>two</p>")
        // Never-interrupted queued work is untouched.
        XCTAssertEqual(byID[queuedOp.id]?.state, .queued)
        XCTAssertEqual(byID[queuedOp.id]?.attempts, 0)
    }

    func testRestartPreservesAllDurableState() async throws {
        let dir = track(makeStoreDirectory())
        let src = try makeSourceFile(contents: "staged-payload")
        var store: AccountStore? = try AccountStore(directory: dir)
        let staged = try await store!.stage(file: src)
        try await store!.saveDraft(Draft(channelID: "c1", html: "<p>hello</p>", replyTo: "m0", attachments: [staged], caret: 4))
        let op = try await store!.acceptDraft(channelID: "c1")
        try await store!.saveDraft(Draft(channelID: "c2", html: "<p>second</p>"))
        var inFlight = op
        inFlight.state = .uploading
        inFlight.attempts = 1
        inFlight.attachments[0].uploaded = .object(["file_url": .string("/private/files/x.png")])
        try await store!.updateOperation(inFlight)
        try await store!.cacheMessages([
            makeMessage(id: "m1", channel: "c1", creation: creation(1), text: "<p>first</p>"),
            makeMessage(id: "m2", channel: "c1", creation: creation(2), text: "<p>second</p>"),
            makeMessage(id: "m3", channel: "c2", creation: creation(3), text: "<p>other</p>"),
        ])
        try await store!.cacheChannels([makeChannel(id: "ch1", title: "Beta"), makeChannel(id: "ch2", title: "Alpha")])
        try await store!.cacheProjection(key: "boot", value: .object(["read_only": .bool(false)]))
        try await store!.pendingVisit(channelID: "c1", timestamp: "2026-11-07 10:00:00.000000")
        store = nil

        let reopened = try reopen(directory: dir)
        await XCTAssertNilA(try await reopened.draft(channelID: "c1"))
        await XCTAssertEqualA(try await reopened.draft(channelID: "c2"), Draft(channelID: "c2", html: "<p>second</p>"))
        await XCTAssertEqualA(try await reopened.operations(), [inFlight])
        await XCTAssertEqualA(try await reopened.messages(channelID: "c1").map(\.id), ["m1", "m2"])
        await XCTAssertEqualA(try await reopened.channels().map(\.id), ["ch2", "ch1"]) // sorted by title
        await XCTAssertEqualA(try await reopened.projection(key: "boot"), .object(["read_only": .bool(false)]))
        await XCTAssertNilA(try await reopened.projection(key: "missing"))
        await XCTAssertEqualA(try await reopened.visits(), ["c1": "2026-11-07 10:00:00.000000"])
        await XCTAssertEqualA(try await reopened.search("first").map(\.id), ["m1"])
        // Staged copy is durable and private.
        XCTAssertEqual(try String(contentsOfFile: staged.localPath, encoding: .utf8), "staged-payload")
        XCTAssertEqual(try posixPermissions(URL(fileURLWithPath: staged.localPath)), 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    // MARK: Bounded cache, deletion, FTS with spoiler masking

    func testMessagesCacheIsBoundedAndChronological() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        var batch: [RavenMessage] = []
        for i in 0..<1200 {
            batch.append(makeMessage(id: String(format: "m%04d", i), channel: "c", creation: creation(i), text: "<p>msg \(i)</p>"))
        }
        try await store.cacheMessages(batch)
        try await store.cacheMessages([makeMessage(id: "o1", channel: "other", creation: creation(0), text: "<p>other</p>")])

        let cached = try await store.messages(channelID: "c", limit: 5000)
        XCTAssertEqual(cached.count, AccountStore.maxMessagesPerChannel)
        XCTAssertEqual(cached.first?.id, "m0200")
        XCTAssertEqual(cached.last?.id, "m1199")
        XCTAssertEqual(cached.map(\.id), (200..<1200).map { String(format: "m%04d", $0) })
        // Default limit applies.
        await XCTAssertEqualA(try await store.messages(channelID: "c").count, 500)
        // Other channels are unaffected by the per-channel bound.
        await XCTAssertEqualA(try await store.messages(channelID: "other").map(\.id), ["o1"])
        // The index is bounded together with the cache.
        let results = try await store.search("msg")
        XCTAssertEqual(results.count, AccountStore.maxSearchResults)
        XCTAssertTrue(Set(results.map(\.id)).isSubset(of: Set(cached.map(\.id))))
    }

    func testDeleteMessagesRemovesCacheAndIndexRows() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.cacheMessages([
            makeMessage(id: "d1", channel: "c", creation: creation(1), text: "<p>deletable-word</p>"),
            makeMessage(id: "d2", channel: "c", creation: creation(2), text: "<p>keep-word</p>"),
        ])
        await XCTAssertEqualA(try await store.search("deletable-word").map(\.id), ["d1"])
        try await store.deleteMessages(ids: ["d1", "missing"])
        await XCTAssertEqualA(try await store.messages(channelID: "c").map(\.id), ["d2"])
        await XCTAssertTrueA((try await store.search("deletable-word")).isEmpty)
        await XCTAssertEqualA(try await store.search("keep-word").map(\.id), ["d2"])
    }

    func testSearchMasksSpoilerBodies() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.cacheMessages([
            makeMessage(id: "s1", channel: "c", creation: creation(1),
                        text: "<p>ordinary hello</p><p><span data-spoiler=\"true\">the-eagle-lands-tonight</span></p>"),
            makeMessage(id: "s2", channel: "c", creation: creation(2), text: "<p>eagle outside</p>"),
        ])
        await XCTAssertEqualA(try await store.search("hello").map(\.id), ["s1"])
        // Spoiler-only tokens are not findable...
        await XCTAssertTrueA((try await store.search("the-eagle-lands-tonight")).isEmpty)
        await XCTAssertTrueA((try await store.search("lands")).isEmpty)
        await XCTAssertTrueA((try await store.search("tonight")).isEmpty)
        // ...while the same token outside a spoiler still matches.
        await XCTAssertEqualA(try await store.search("eagle").map(\.id), ["s2"])
        // Empty and oversized queries are bounded no-ops.
        await XCTAssertTrueA((try await store.search("   ")).isEmpty)
        await XCTAssertTrueA((try await store.search(String(repeating: "x", count: 1000))).isEmpty)
    }

    // MARK: Private bounded staging

    func testStageCopiesPrivatelyAndEnforcesBudget() async throws {
        let dir = track(makeStoreDirectory())
        let src = try makeSourceFile(contents: "staged-payload-bytes")
        let store = try AccountStore(directory: dir)

        let staged = try await store.stage(file: src)
        let stagingDir = dir.appendingPathComponent(AccountStore.stagingDirectoryName)
        XCTAssertTrue(staged.localPath.hasPrefix(stagingDir.path + "/"))
        XCTAssertEqual(staged.filename, src.lastPathComponent)
        XCTAssertNil(staged.uploaded)
        XCTAssertEqual(try String(contentsOfFile: staged.localPath, encoding: .utf8), "staged-payload-bytes")
        XCTAssertEqual(try posixPermissions(URL(fileURLWithPath: staged.localPath)), 0o600)
        XCTAssertEqual(try posixPermissions(stagingDir), 0o700)
        // The original stays where it was; only the private copy is referenced.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))

        let q = try openDB(dir)
        await XCTAssertEqualA(try await fetchInt64(q, "SELECT COUNT(*) FROM staging"), 1)

        // Budget: staging beyond maxStagingBytes throws and stages nothing.
        await store.setMaxStagingBytes(10)
        let budgetError = await captureError { try await store.stage(file: src) }
        XCTAssertEqual(budgetError as? StoreError, .stagingBudgetExceeded(10))
        await XCTAssertEqualA(try await fetchInt64(q, "SELECT COUNT(*) FROM staging"), 1)

        // Missing sources are rejected.
        let missing = dir.appendingPathComponent("no-such-file")
        let missingError = await captureError { try await store.stage(file: missing) }
        XCTAssertEqual(missingError as? StoreError, .sourceNotReadable(missing))
    }

    // MARK: Watermarks and mark-unread generation guard

    func testWatermarksAreMonotonicAndPersistedAcrossRestart() async throws {
        let dir = track(makeStoreDirectory())
        var store: AccountStore? = try AccountStore(directory: dir)
        try await store!.pendingVisit(channelID: "c", timestamp: "2026-11-07 10:02:00.000000")
        try await store!.pendingVisit(channelID: "c", timestamp: "2026-11-07 10:01:00.000000") // older: ignored
        try await store!.pendingVisit(channelID: "d", timestamp: "2026-11-07 09:00:00.000000")
        await XCTAssertEqualA(try await store!.visits(), ["c": "2026-11-07 10:02:00.000000", "d": "2026-11-07 09:00:00.000000"])
        store = nil

        let reopened = try reopen(directory: dir)
        await XCTAssertEqualA(try await reopened.visits(), ["c": "2026-11-07 10:02:00.000000", "d": "2026-11-07 09:00:00.000000"])

        // A stale (older) completion must not delete the newer watermark.
        try await reopened.pendingVisit(channelID: "c", timestamp: "2026-11-07 10:03:00.000000")
        try await reopened.completeVisit(channelID: "c", timestamp: "2026-11-07 10:02:00.000000")
        await XCTAssertEqualA(try await reopened.visits(), ["c": "2026-11-07 10:03:00.000000", "d": "2026-11-07 09:00:00.000000"])
        // The exact current watermark completes.
        try await reopened.completeVisit(channelID: "c", timestamp: "2026-11-07 10:03:00.000000")
        await XCTAssertEqualA(try await reopened.visits(), ["d": "2026-11-07 09:00:00.000000"])
    }

    func testMarkUnreadDeletesQueuedVisitAndBlocksStaleCompletion() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        let q = try openDB(dir)

        try await store.pendingVisit(channelID: "c", timestamp: "t1")
        await XCTAssertEqualA(try await store.visits(), ["c": "t1"])

        try await store.markUnread(channelID: "c")
        // The queued visit is deleted immediately...
        await XCTAssertTrueA((try await store.visits()).isEmpty)
        // ...and a new local unread generation is persisted.
        await XCTAssertEqualA(try await fetchInt64(q, "SELECT generation FROM unread_generations WHERE channelID = 'c'"), 1)

        // A stale completion of the pre-markUnread visit is a no-op.
        try await store.completeVisit(channelID: "c", timestamp: "t1")
        await XCTAssertTrueA((try await store.visits()).isEmpty)

        // A later watermark queued after the unread mark...
        try await store.pendingVisit(channelID: "c", timestamp: "t2")
        // ...is not deleted by the stale t1 completion...
        try await store.completeVisit(channelID: "c", timestamp: "t1")
        await XCTAssertEqualA(try await store.visits(), ["c": "t2"])
        // ...and is removed only by its own completion.
        try await store.completeVisit(channelID: "c", timestamp: "t2")
        await XCTAssertTrueA((try await store.visits()).isEmpty)

        try await store.markUnread(channelID: "c")
        await XCTAssertEqualA(try await fetchInt64(q, "SELECT generation FROM unread_generations WHERE channelID = 'c'"), 2)
    }

    // MARK: Channels, revoked access, projections, clear history

    func testCollectionCacheEvictsOldSnapshotsWithoutTouchingDrafts() async throws {
        let store = try AccountStore(directory: track(makeStoreDirectory()))
        try await store.saveDraft(Draft(channelID: "c", html: "recover me"))
        for index in 0..<AccountStore.maxProjections {
            try await store.cacheProjection(key: "q\(index)", value: .string("snapshot \(index)"))
        }
        // Refreshing a snapshot makes it newer than the next evicted one.
        try await store.cacheProjection(key: "q0", value: .string("refreshed"))
        try await store.cacheProjection(key: "new", value: .string("latest"))
        await XCTAssertEqualA(try await store.projection(key: "q0"), .string("refreshed"))
        await XCTAssertEqualA(try await store.projection(key: "q1"), nil)
        await XCTAssertEqualA(try await store.draft(channelID: "c")?.html, "recover me")
        try await store.cacheProjection(key: "new", value: .string(String(repeating: "x", count: AccountStore.maxProjectionBytes)))
        await XCTAssertEqualA(try await store.projection(key: "new"), nil)
    }

    func testCollectionCacheHasAnAggregateByteBudget() async throws {
        let store = try AccountStore(directory: track(makeStoreDirectory()))
        let payload = JSONValue.string(String(repeating: "x", count: AccountStore.maxProjectionBytes - 16))
        for index in 0..<10 { try await store.cacheProjection(key: "large\(index)", value: payload) }
        await XCTAssertEqualA(try await store.projection(key: "large0"), nil)
        await XCTAssertEqualA(try await store.projection(key: "large9"), payload)
    }

    func testRemoveRevokedChannelsDeletesChannelAndHistoryButNotUnsentWork() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.cacheChannels([makeChannel(id: "c1", title: "Alpha"), makeChannel(id: "c2", title: "Beta")])
        try await store.cacheMessages([
            makeMessage(id: "r1", channel: "c1", creation: creation(1), text: "<p>revoked-secret-word</p>"),
            makeMessage(id: "k1", channel: "c2", creation: creation(2), text: "<p>kept-word</p>"),
        ])
        try await store.saveDraft(Draft(channelID: "c1", html: "unsent"))
        let op = try await store.acceptDraft(channelID: "c1")

        try await store.removeRevokedChannels(allowed: ["c2"])
        await XCTAssertEqualA(try await store.channels().map(\.id), ["c2"])
        await XCTAssertTrueA((try await store.messages(channelID: "c1")).isEmpty)
        await XCTAssertTrueA((try await store.search("revoked-secret-word")).isEmpty)
        await XCTAssertEqualA(try await store.search("kept-word").map(\.id), ["k1"])
        // Drafts and the outbox are durable unsent work: never revoked away.
        await XCTAssertEqualA(try await store.operations().map(\.id), [op.id])
    }

    func testClearHistoryPreservesUnsentWorkAndClearsReceivedProjections() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.cacheChannels([makeChannel(id: "c1", title: "Alpha")])
        try await store.cacheMessages([makeMessage(id: "m1", channel: "c1", creation: creation(1), text: "<p>gone-word</p>")])
        try await store.saveDraft(Draft(channelID: "c1", html: "send"))
        let op = try await store.acceptDraft(channelID: "c1")
        try await store.saveDraft(Draft(channelID: "c2", html: "draft"))
        try await store.cacheProjection(key: "k", value: .string("v"))
        try await store.pendingVisit(channelID: "c1", timestamp: "t1")

        try await store.clearHistory()
        await XCTAssertTrueA((try await store.messages(channelID: "c1")).isEmpty)
        await XCTAssertTrueA((try await store.search("gone-word")).isEmpty)
        await XCTAssertEqualA(try await store.draft(channelID: "c2")?.html, "draft")
        await XCTAssertEqualA(try await store.operations().map(\.id), [op.id])
        await XCTAssertEqualA(try await store.visits(), ["c1": "t1"])
        await XCTAssertEqualA(try await store.channels().map(\.id), ["c1"])
        await XCTAssertTrueA(try await store.projection(key: "k") == nil)
    }

    func testOutboxIsNeverAgeDeleted() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        try await store.saveDraft(Draft(channelID: "c", html: "old send"))
        let op = try await store.acceptDraft(channelID: "c")
        // Age the row artificially (the 24h pause-for-review policy lives in the
        // app layer; storage itself must never expire durable work).
        let q = try openDB(dir)
        try await q.write { db in
            try db.execute(sql: "UPDATE operations SET createdAt = 0 WHERE id = ?", arguments: [op.id.uuidString])
        }
        try await store.cacheMessages([makeMessage(id: "m1", channel: "c", creation: creation(1), text: "<p>x</p>")])
        try await store.cacheChannels([makeChannel(id: "c", title: "Alpha")])

        try await store.clearHistory()
        try await store.removeRevokedChannels(allowed: [])
        try await store.recoverInterruptedOperations()
        let ops = try await store.operations()
        XCTAssertEqual(ops.map(\.id), [op.id])
        XCTAssertEqual(ops[0].html, "old send")
    }

    func testProjectionsRoundTrip() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        await XCTAssertNilA(try await store.projection(key: "k"))
        try await store.cacheProjection(key: "k", value: .array([.number(1), .string("two"), .bool(true), .null]))
        await XCTAssertEqualA(try await store.projection(key: "k"), .array([.number(1), .string("two"), .bool(true), .null]))
        try await store.cacheProjection(key: "k", value: .object(["nested": .object(["a": .number(2)])]))
        await XCTAssertEqualA(try await store.projection(key: "k"), .object(["nested": .object(["a": .number(2)])]))
    }

    // MARK: Isolation

    func testStoresOnDifferentDirectoriesAreFullyIsolated() async throws {
        let dirA = track(makeStoreDirectory())
        let dirB = track(makeStoreDirectory())
        let a = try AccountStore(directory: dirA)
        let b = try AccountStore(directory: dirB)

        try await a.saveDraft(Draft(channelID: "cA", html: "A"))
        let opA = try await a.acceptDraft(channelID: "cA")
        try await a.cacheMessages([makeMessage(id: "mA", channel: "cA", creation: creation(1), text: "<p>alpha-word</p>")])
        try await a.cacheChannels([makeChannel(id: "chA", title: "A")])
        try await a.cacheProjection(key: "k", value: .string("A"))
        try await a.pendingVisit(channelID: "cA", timestamp: "tA")

        await XCTAssertNilA(try await b.draft(channelID: "cA"))
        await XCTAssertTrueA((try await b.operations()).isEmpty)
        await XCTAssertTrueA((try await b.messages(channelID: "cA")).isEmpty)
        await XCTAssertTrueA((try await b.channels()).isEmpty)
        await XCTAssertNilA(try await b.projection(key: "k"))
        await XCTAssertTrueA((try await b.visits()).isEmpty)
        await XCTAssertTrueA((try await b.search("alpha-word")).isEmpty)

        await XCTAssertEqualA(try await a.operations().map(\.id), [opA.id])
        await XCTAssertEqualA(try await a.search("alpha-word").map(\.id), ["mA"])
    }

    func testConcurrentAccessIsSerializedByTheActor() async throws {
        let dir = track(makeStoreDirectory())
        let store = try AccountStore(directory: dir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { try? await store.saveDraft(Draft(channelID: "c\(i % 4)", html: "html-\(i)", caret: i)) }
                group.addTask { try? await store.pendingVisit(channelID: "shared", timestamp: "2026-11-07 10:\(String(format: "%02d", i)):00.000000") }
                group.addTask { try? await store.cacheMessages([RavenMessage(raw: .object(["name": .string("m\(i)"), "channel_id": .string("c\(i % 4)"), "creation": .string("2026-01-01 00:00:00.00000\(i % 10)"), "text": .string("<p>concurrent \(i)</p>")]))]) }
            }
        }
        // Monotonic watermark: the highest timestamp wins under concurrency.
        await XCTAssertEqualA(try await store.visits(), ["shared": "2026-11-07 10:39:00.000000"])
        for c in 0..<4 {
            let html = try await store.draft(channelID: "c\(c)")?.html
            XCTAssertNotNil(html?.hasPrefix("html-"))
        }
        await XCTAssertEqualA(try await store.search("concurrent").count, 40)
    }
}
