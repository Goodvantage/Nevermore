import Foundation
import GRDB
import RavenProtocol
import SwiftSoup
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Public value types

/// A file copied into the account store's private staging area.
/// `localPath` always points inside the store directory, never at a Finder URL.
public struct StagedAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var localPath: String
    public var filename: String
    /// Server upload result (File identifiers/URLs) once an upload completed.
    /// Mutable on a queued operation; the identity/path of the staging copy is not.
    public var uploaded: JSONValue?
    public init(id: UUID = UUID(), localPath: String, filename: String, uploaded: JSONValue? = nil) {
        self.id = id
        self.localPath = localPath
        self.filename = filename
        self.uploaded = uploaded
    }
}

/// A recoverable per-channel composer draft.
public struct Draft: Codable, Sendable, Equatable {
    public var channelID: String
    public var html: String
    public var replyTo: String?
    public var attachments: [StagedAttachment]
    public var caret: Int
    public var editorState: DraftEditorState?
    public init(channelID: String, html: String = "", replyTo: String? = nil, attachments: [StagedAttachment] = [], caret: Int = 0, editorState: DraftEditorState? = nil) {
        self.channelID = channelID
        self.html = html
        self.replyTo = replyTo
        self.attachments = attachments
        self.caret = caret
        self.editorState = editorState
    }
}

public enum SendState: String, Codable, Sendable {
    case queued, uploading, sending, acknowledged, retryable, needsReview, rejected, cancelled
}

/// One durable, immutable logical send. `id` is the client idempotency key
/// (`client_id`) reused on every retry. The payload (channel, html, reply,
/// attachment identity, creation time) never changes after acceptance; only
/// state, attempts, error and upload metadata may be updated.
public struct SendOperation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var channelID: String
    public var html: String
    public var replyTo: String?
    public var attachments: [StagedAttachment]
    public var createdAt: Date
    public var state: SendState
    public var attempts: Int
    public var error: String?
    /// Optional for compatibility with outbox records from earlier builds.
    /// Nil and false both mean a normal send. Frozen at acceptance, never recomputed on retry.
    public var sendSilently: Bool?
    public init(id: UUID = UUID(), channelID: String, html: String, replyTo: String? = nil, attachments: [StagedAttachment] = [], createdAt: Date = Date(), state: SendState = .queued, attempts: Int = 0, error: String? = nil, sendSilently: Bool = false) {
        self.id = id
        self.channelID = channelID
        self.html = html
        self.replyTo = replyTo
        self.attachments = attachments
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.error = error
        self.sendSilently = sendSilently
    }
}

// MARK: - Errors

public enum StoreError: Error, Sendable, Equatable {
    case directoryInUse(URL)
    case lockFailed(URL)
    case draftNotFound(String)
    case operationNotFound(UUID)
    /// A queued operation's payload or id was mutated outside the allowed
    /// fields (state, attempts, error, attachment upload metadata).
    case immutableFieldChanged(String)
    case invalidAcknowledgement(String)
    case sourceNotReadable(URL)
    case stagingBudgetExceeded(Int64)
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .directoryInUse(let url): return StatusLocalization.text(.storeDirectoryInUse, arguments: [url.path])
        case .lockFailed(let url): return StatusLocalization.text(.storeLockFailed, arguments: [url.path])
        case .draftNotFound(let channelID): return StatusLocalization.text(.draftNotFound, arguments: [channelID])
        case .operationNotFound(let id): return StatusLocalization.text(.operationNotFound, arguments: [id.uuidString])
        case .immutableFieldChanged(let field): return StatusLocalization.text(.immutableField, arguments: [field])
        case .invalidAcknowledgement(let reason): return StatusLocalization.text(.invalidAcknowledgement, arguments: [reason])
        case .sourceNotReadable(let url): return StatusLocalization.text(.sourceNotReadable, arguments: [url.path])
        case .stagingBudgetExceeded(let budget): return StatusLocalization.text(.stagingBudget, arguments: [budget])
        }
    }
}

// MARK: - AccountStore

/// Per-account durable store (SQLite via GRDB plus a private staging directory).
///
/// The `directory` is uniquely account-scoped: opening a second store on the
/// same directory while one is alive throws `StoreError.directoryInUse`.
/// Drafts and the send outbox are durable and are never age-deleted; only
/// received history and channels are bounded/evictable.
public actor AccountStore {
    public static let databaseFileName = "store.sqlite"
    public static let lockFileName = "store.lock"
    public static let stagingDirectoryName = "staging"

    /// Bounds for the received-message cache (a bounded cache, not an archive).
    public static let maxMessagesPerChannel = 1000
    public static let maxMessagesTotal = 20000
    public static let maxMessagesQueryLimit = 10000
    /// Bounds for the local full-text index.
    public static let maxSearchTextLength = 20000
    public static let maxSearchableHTMLLength = 200_000
    public static let maxSearchQueryLength = 256
    public static let maxSearchResults = 100
    /// Collection snapshots are disposable; drafts/outbox never share this budget.
    public static let maxProjections = 64
    public static let maxProjectionBytes = 2 * 1024 * 1024
    public static let maxProjectionsTotalBytes = 16 * 1024 * 1024
    /// Default bound for private attachment staging copies.
    public static let defaultMaxStagingBytes: Int64 = 256 * 1024 * 1024

    /// Maximum total bytes of staged attachment copies. Staging beyond this
    /// throws. Adjust with `setMaxStagingBytes` (storage control).
    public private(set) var maxStagingBytes: Int64

    /// Adjusts the staging byte budget.
    public func setMaxStagingBytes(_ bytes: Int64) { maxStagingBytes = bytes }

    private let directory: URL
    private let queue: DatabaseQueue
    private let lockDescriptor: Int32

    public init(directory: URL) throws {
        self.directory = directory
        self.maxStagingBytes = Self.defaultMaxStagingBytes
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let staging = directory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        // The directory belongs to exactly one account store at a time.
        let lockPath = directory.appendingPathComponent(Self.lockFileName).path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw StoreError.lockFailed(directory) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? StoreError.directoryInUse(directory) : StoreError.lockFailed(directory)
        }
        self.lockDescriptor = fd

        do {
            let dbPath = directory.appendingPathComponent(Self.databaseFileName).path
            let queue = try DatabaseQueue(path: dbPath)
            var migrator = DatabaseMigrator()
            Self.registerMigrations(&migrator)
            try migrator.migrate(queue)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath)
            self.queue = queue
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(lockDescriptor) }

    // MARK: Explicit schema migrations

    private static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.create(table: "drafts") { t in
                t.column("channelID", .text).primaryKey()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "operations") { t in
                t.column("id", .text).primaryKey()
                t.column("channelID", .text).notNull()
                t.column("state", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("attempts", .integer).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("channelID", .text).notNull()
                t.column("creation", .text).notNull()
                t.column("owner", .text).notNull()
                t.column("raw", .blob).notNull()
            }
            try db.create(table: "channels") { t in
                t.column("id", .text).primaryKey()
                t.column("raw", .blob).notNull()
            }
            try db.create(table: "projections") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .blob).notNull()
            }
            // Persisted pending read watermarks, each tagged with the unread
            // generation it was queued in so stale completions cannot clear them.
            try db.create(table: "visits") { t in
                t.column("channelID", .text).primaryKey()
                t.column("timestamp", .text).notNull()
                t.column("generation", .integer).notNull()
            }
            try db.create(table: "unread_generations") { t in
                t.column("channelID", .text).primaryKey()
                t.column("generation", .integer).notNull()
            }
            try db.create(table: "staging") { t in
                t.column("id", .text).primaryKey()
                t.column("path", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            // Local full-text index over cached messages. The indexed body is
            // derived with spoiler contents masked out (see searchText(for:)).
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.column("id").notIndexed()
                t.column("body")
            }
            try db.create(index: "messages_channel_creation", on: "messages", columns: ["channelID", "creation", "id"])
            try db.create(index: "operations_state", on: "operations", columns: ["state"])
        }
    }

    // MARK: Drafts and the send outbox

    public func saveDraft(_ draft: Draft) async throws {
        let payload = try Self.encode(draft)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO drafts(channelID, payload) VALUES (?, ?) ON CONFLICT(channelID) DO UPDATE SET payload = excluded.payload",
                arguments: [draft.channelID, payload])
        }
    }

    public func draft(channelID: String) async throws -> Draft? {
        try await queue.read { db -> Draft? in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM drafts WHERE channelID = ?", arguments: [channelID]) else { return nil }
            return try Self.decode(Draft.self, from: data)
        }
    }

    /// Atomically converts the channel's draft into a durable queued
    /// `SendOperation` (fresh client idempotency key) and deletes the draft.
    /// Either both happen or neither does: if the operation cannot be
    /// persisted, the draft is left untouched.
    public func acceptDraft(channelID: String, expected: Draft? = nil, sendSilently: Bool = false) async throws -> SendOperation {
        try await queue.write { db -> SendOperation in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM drafts WHERE channelID = ?", arguments: [channelID]) else {
                throw StoreError.draftNotFound(channelID)
            }
            let draft = try Self.decode(Draft.self, from: data)
            if let expected, draft.html != expected.html || draft.replyTo != expected.replyTo || draft.attachments != expected.attachments || !DraftEditorState.sameContent(draft.editorState, expected.editorState) {
                throw StoreError.immutableFieldChanged("shared draft changed before acceptance")
            }
            let validatedHTML = try draft.validatedHTML()
            let operation = SendOperation(
                id: UUID(),
                channelID: draft.channelID,
                html: validatedHTML,
                replyTo: draft.replyTo,
                attachments: draft.attachments,
                createdAt: Date(),
                state: .queued,
                attempts: 0,
                error: nil,
                sendSilently: sendSilently)
            try Self.insertOperation(db, operation)
            try db.execute(sql: "DELETE FROM drafts WHERE channelID = ?", arguments: [channelID])
            return operation
        }
    }

    /// All non-terminal operations (excludes acknowledged and cancelled).
    /// Terminal rows are retained durably; they are simply not pending work.
    public func operations() async throws -> [SendOperation] {
        try await queue.read { db in
            let rows = try Data.fetchAll(db, sql: "SELECT payload FROM operations WHERE state NOT IN ('acknowledged', 'cancelled') ORDER BY createdAt, id")
            return try rows.map { try Self.decode(SendOperation.self, from: $0) }
        }
    }

    /// Updates an operation's mutable fields only: state, attempts, error and
    /// attachment upload metadata. Any change to the id or payload (channel,
    /// html, reply, attachment identity/path/filename, creation time) throws
    /// `StoreError.immutableFieldChanged` and leaves the stored row untouched.
    /// Returns false for a terminal row: a stale preflight/upload completion
    /// must never revive an acknowledged or cancelled send.
    @discardableResult public func updateOperation(_ operation: SendOperation) async throws -> Bool {
        let payload = try Self.encode(operation)
        return try await queue.write { db -> Bool in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM operations WHERE id = ?", arguments: [operation.id.uuidString]) else {
                throw StoreError.operationNotFound(operation.id)
            }
            let existing = try Self.decode(SendOperation.self, from: data)
            if existing.channelID != operation.channelID
                || existing.html != operation.html
                || existing.replyTo != operation.replyTo
                || (existing.sendSilently == true) != (operation.sendSilently == true)
                || existing.createdAt != operation.createdAt {
                throw StoreError.immutableFieldChanged("payload")
            }
            if existing.attachments.count != operation.attachments.count {
                throw StoreError.immutableFieldChanged("attachments")
            }
            for (before, after) in zip(existing.attachments, operation.attachments) {
                if before.id != after.id || before.localPath != after.localPath || before.filename != after.filename {
                    throw StoreError.immutableFieldChanged("attachments")
                }
            }
            guard existing.state != .cancelled, existing.state != .acknowledged else { return false }
            try db.execute(
                sql: "UPDATE operations SET channelID = ?, state = ?, createdAt = ?, attempts = ?, payload = ? WHERE id = ?",
                arguments: [operation.channelID, operation.state.rawValue, operation.createdAt.timeIntervalSince1970, operation.attempts, payload, operation.id.uuidString])
            return true
        }
    }

    /// Atomically cancels a send that has never been attempted and returns
    /// it, so its text can go back to the composer. Returns nil when the
    /// send is missing or has moved on (see `InkRules.canTakeBack`); the
    /// check and the change share one transaction, so a flush that has
    /// already claimed the send cannot be undercut.
    public func takeBack(id: UUID) async throws -> SendOperation? {
        try await queue.write { db -> SendOperation? in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM operations WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            var operation = try Self.decode(SendOperation.self, from: data)
            guard InkRules.canTakeBack(operation) else { return nil }
            operation.state = .cancelled
            try Self.replaceOperation(db, operation)
            return operation
        }
    }

    public enum TakeBackResult: Sendable, Equatable {
        case restored(SendOperation), draftChanged, unavailable
    }

    /// Cancels the original conversation's send and restores its draft in
    /// one transaction. The caller's empty draft snapshot must still match;
    /// a newer draft or a delivery claim leaves both records untouched.
    public func takeBack(id: UUID, channelID: String, replacingDraft expected: Draft?) async throws -> TakeBackResult {
        guard InkRules.canRestoreDraft(expected) else { return .draftChanged }
        return try await queue.write { db -> TakeBackResult in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM operations WHERE id = ?", arguments: [id.uuidString]) else { return .unavailable }
            var operation = try Self.decode(SendOperation.self, from: data)
            guard operation.channelID == channelID, InkRules.canTakeBack(operation) else { return .unavailable }
            let draftData = try Data.fetchOne(db, sql: "SELECT payload FROM drafts WHERE channelID = ?", arguments: [channelID])
            let current = try draftData.map { try Self.decode(Draft.self, from: $0) }
            guard current == expected else { return .draftChanged }
            let restored = Draft(channelID: channelID, html: operation.html, replyTo: operation.replyTo, attachments: operation.attachments, caret: Int.max)
            operation.state = .cancelled
            try Self.replaceOperation(db, operation)
            try db.execute(
                sql: "INSERT INTO drafts(channelID, payload) VALUES (?, ?) ON CONFLICT(channelID) DO UPDATE SET payload = excluded.payload",
                arguments: [channelID, try Self.encode(restored)])
            return .restored(operation)
        }
    }

    /// Atomically parks a waiting send for review, with the reason shown
    /// in the outbox. Returns false, changing nothing, when the stored send
    /// is no longer waiting: writing a stale copy back would undo a take
    /// back that happened since the caller listed it.
    public func sendToReview(id: UUID, reason: String) async throws -> Bool {
        try await queue.write { db -> Bool in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM operations WHERE id = ?", arguments: [id.uuidString]) else { return false }
            var operation = try Self.decode(SendOperation.self, from: data)
            guard operation.state == .queued || operation.state == .retryable else { return false }
            operation.state = .needsReview
            operation.error = reason
            try Self.replaceOperation(db, operation)
            return true
        }
    }

    /// Atomically claims a queued or retryable send for one delivery
    /// attempt (state `uploading`, attempts + 1) and returns the claimed
    /// copy. Returns nil when the stored send is no longer waiting, for
    /// example because it was taken back after the caller listed it.
    public func beginAttempt(id: UUID) async throws -> SendOperation? {
        try await queue.write { db -> SendOperation? in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM operations WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            var operation = try Self.decode(SendOperation.self, from: data)
            guard operation.state == .queued || operation.state == .retryable else { return nil }
            operation.attempts += 1
            operation.state = .uploading
            try Self.replaceOperation(db, operation)
            return operation
        }
    }

    /// Atomically marks the operation acknowledged and caches the server's
    /// returned messages (and their search index rows) in the same
    /// transaction: if anything fails, the operation stays non-terminal and
    /// no partial message cache is written.
    public func acknowledge(id: UUID, messages: [RavenMessage]) async throws {
        try await queue.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM operations WHERE id = ?", arguments: [id.uuidString]) else {
                throw StoreError.operationNotFound(id)
            }
            var operation = try Self.decode(SendOperation.self, from: data)
            guard !messages.isEmpty else { throw StoreError.invalidAcknowledgement("empty message list") }
            for message in messages {
                guard message.channelID == operation.channelID else {
                    throw StoreError.invalidAcknowledgement("message \(message.id) belongs to channel \(message.channelID)")
                }
                if let batch = message.batchID, batch != id.uuidString {
                    throw StoreError.invalidAcknowledgement("message \(message.id) has batch \(batch)")
                }
            }
            for message in messages { try Self.upsertMessage(db, message) }
            operation.state = .acknowledged
            try Self.replaceOperation(db, operation)
            try Self.trimMessages(db)
        }
        try? await pruneStaging()
    }

    /// Reclaims only explicitly discarded or terminal-send staging files that
    /// no remaining draft/nonterminal send references. Unaccepted fresh staging
    /// copies are retained unless the user explicitly discards them.
    public func pruneStaging(discarding ids: Set<UUID> = []) async throws {
        let candidates: [(String, String)] = try await queue.read { db in
            let drafts = try Data.fetchAll(db, sql: "SELECT payload FROM drafts").map { try Self.decode(Draft.self, from: $0) }
            let operations = try Data.fetchAll(db, sql: "SELECT payload FROM operations").map { try Self.decode(SendOperation.self, from: $0) }
            let protected = Set(drafts.flatMap { $0.attachments.map(\.id) } + operations.filter { $0.state != .acknowledged && $0.state != .cancelled }.flatMap { $0.attachments.map(\.id) })
            let terminal = Set(operations.filter { $0.state == .acknowledged || $0.state == .cancelled }.flatMap { $0.attachments.map(\.id) }).union(ids)
            return try Row.fetchAll(db, sql: "SELECT id, path FROM staging").compactMap { row in
                let name: String = row["id"], path: String = row["path"]
                guard let id = UUID(uuidString: name), terminal.contains(id), !protected.contains(id) else { return nil }
                return (name, path)
            }
        }
        for (id, path) in candidates {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL == directory.appendingPathComponent(Self.stagingDirectoryName).standardizedFileURL else { continue }
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(at: url) }
            try await queue.write { db in try db.execute(sql: "DELETE FROM staging WHERE id = ?", arguments: [id]) }
        }
    }

    /// After an interruption (process death mid-flight) operations left in
    /// `uploading`/`sending` are returned to `retryable` with their original
    /// immutable payload, id, attempts and completed upload metadata intact,
    /// so the serialized retry path resumes them without re-uploading.
    public func recoverInterruptedOperations() async throws {
        try await queue.write { db in
            let rows = try Data.fetchAll(db, sql: "SELECT payload FROM operations WHERE state IN ('uploading', 'sending')")
            for data in rows {
                var operation = try Self.decode(SendOperation.self, from: data)
                operation.state = .retryable
                try Self.replaceOperation(db, operation)
            }
        }
    }

    // MARK: Bounded received-history cache and search

    public func cacheMessages(_ messages: [RavenMessage]) async throws {
        guard !messages.isEmpty else { return }
        try await queue.write { db in
            for message in messages { try Self.upsertMessage(db, message) }
            try Self.trimMessages(db)
        }
    }

    /// Cached messages for a channel in chronological order (oldest first).
    public func messages(channelID: String, limit: Int = 500) async throws -> [RavenMessage] {
        let bounded = max(1, min(limit, Self.maxMessagesQueryLimit))
        return try await queue.read { db in
            let rows = try Data.fetchAll(
                db,
                sql: "SELECT raw FROM messages WHERE channelID = ? ORDER BY creation DESC, id DESC LIMIT ?",
                arguments: [channelID, bounded])
            return try rows.reversed().map { try Self.decode(RavenMessage.self, from: $0) }
        }
    }

    public func deleteMessages(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await queue.write { db in
            for chunk in ids.chunked(into: 500) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM messages_fts WHERE id IN (\(marks))", arguments: StatementArguments(chunk))
                try db.execute(sql: "DELETE FROM messages WHERE id IN (\(marks))", arguments: StatementArguments(chunk))
            }
        }
    }

    /// Full-text search over the bounded cached history. Spoiler bodies
    /// (`data-spoiler`) are masked out of the index, so they can never leak
    /// into local search matches or snippets.
    public func search(_ query: String) async throws -> [RavenMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxSearchQueryLength else { return [] }
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
        return try await queue.read { db in
            let rows = try Data.fetchAll(
                db,
                sql: "SELECT m.raw FROM messages_fts f JOIN messages m ON m.id = f.id WHERE messages_fts MATCH ? ORDER BY rank LIMIT ?",
                arguments: [match, Self.maxSearchResults])
            return try rows.map { try Self.decode(RavenMessage.self, from: $0) }
        }
    }

    /// Clears received history (messages and their index rows) only. Drafts,
    /// the send outbox, visits, channels, projections and staging survive.
    public func clearHistory() async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM messages_fts")
            try db.execute(sql: "DELETE FROM projections")
        }
    }

    // MARK: Channels

    public func cacheChannels(_ channels: [RavenChannel]) async throws {
        guard !channels.isEmpty else { return }
        try await queue.write { db in
            for channel in channels {
                let raw = try Self.encode(channel)
                try db.execute(
                    sql: "INSERT INTO channels(id, raw) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET raw = excluded.raw",
                    arguments: [channel.id, raw])
            }
        }
    }

    public func channels() async throws -> [RavenChannel] {
        try await queue.read { db in
            let rows = try Data.fetchAll(db, sql: "SELECT raw FROM channels")
            return try rows
                .map { try Self.decode(RavenChannel.self, from: $0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// Removes cached channels no longer allowed (revoked access) together with
    /// their cached messages and index rows. Drafts and queued sends for those
    /// channels are durable unsent work and are deliberately retained.
    public func removeRevokedChannels(allowed: Set<String>) async throws {
        try await queue.write { db in
            let revoked = try String.fetchAll(db, sql: "SELECT id FROM channels").filter { !allowed.contains($0) }
            if !revoked.isEmpty { try db.execute(sql: "DELETE FROM projections") }
            for chunk in revoked.chunked(into: 500) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM channels WHERE id IN (\(marks))", arguments: StatementArguments(chunk))
                try db.execute(
                    sql: "DELETE FROM messages_fts WHERE id IN (SELECT id FROM messages WHERE channelID IN (\(marks)))",
                    arguments: StatementArguments(chunk))
                try db.execute(sql: "DELETE FROM messages WHERE channelID IN (\(marks))", arguments: StatementArguments(chunk))
            }
        }
    }

    // MARK: Private bounded staging

    /// Copies a file into the account-private staging directory (0700 dir,
    /// 0600 file) and returns its staged attachment. The total staged size is
    /// bounded by `maxStagingBytes`; exceeding it throws and stages nothing.
    public func stage(file: URL) async throws -> StagedAttachment {
        let source = file.resolvingSymlinksInPath(), destinationDirectory = directory.appendingPathComponent(Self.stagingDirectoryName)
        let budget = maxStagingBytes, filename = Self.sanitizeFilename(file.lastPathComponent)
        return try await queue.write { db in
            let fm = FileManager.default
            guard let attributes = try? fm.attributesOfItem(atPath: source.path) else { throw StoreError.sourceNotReadable(file) }
            guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber else { throw StoreError.sourceNotReadable(file) }
            let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM staging") ?? 0
            let limit = min(64 * 1024 * 1024, budget - total)
            guard size.int64Value <= limit else { throw StoreError.stagingBudgetExceeded(min(budget, 64 * 1024 * 1024)) }
            let id = UUID(), destination = destinationDirectory.appendingPathComponent(UUID().uuidString)
            do {
                guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw StoreError.sourceNotReadable(file) }
                let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
                defer { try? input.close(); try? output.close() }
                var copied: Int64 = 0
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    copied += Int64(chunk.count)
                    guard copied <= limit else { throw StoreError.stagingBudgetExceeded(min(budget, 64 * 1024 * 1024)) }
                    try output.write(contentsOf: chunk)
                }
                try output.synchronize()
                try db.execute(sql: "INSERT INTO staging(id, path, filename, size, createdAt) VALUES (?, ?, ?, ?, ?)", arguments: [id.uuidString, destination.path, filename, copied, Date().timeIntervalSince1970])
                return StagedAttachment(id: id, localPath: destination.path, filename: filename)
            } catch { try? fm.removeItem(at: destination); throw error }
        }
    }

    // MARK: Cached projections

    public func cacheProjection(key: String, value: JSONValue) async throws {
        let data = try Self.encode(value)
        try await queue.write { db in
            // Reinsert to make rowid the write order, including refreshed keys.
            // An oversized replacement must also remove a stale old snapshot.
            try db.execute(sql: "DELETE FROM projections WHERE key = ?", arguments: [key])
            guard data.count <= Self.maxProjectionBytes else { return }
            try db.execute(
                sql: "INSERT INTO projections(key, value) VALUES (?, ?)",
                arguments: [key, data])
            try db.execute(sql: "DELETE FROM projections WHERE rowid NOT IN (SELECT rowid FROM projections ORDER BY rowid DESC LIMIT ?)", arguments: [Self.maxProjections])
            while (try Int.fetchOne(db, sql: "SELECT coalesce(sum(length(value)), 0) FROM projections") ?? 0) > Self.maxProjectionsTotalBytes {
                try db.execute(sql: "DELETE FROM projections WHERE rowid = (SELECT min(rowid) FROM projections)")
            }
        }
    }

    public func projection(key: String) async throws -> JSONValue? {
        try await queue.read { db -> JSONValue? in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM projections WHERE key = ?", arguments: [key]) else { return nil }
            return try Self.decode(JSONValue.self, from: data)
        }
    }

    // MARK: Read watermarks (persisted, monotonic, generation-guarded)

    /// Queues a read watermark. Watermarks only advance: an older timestamp
    /// never replaces a newer pending one.
    public func pendingVisit(channelID: String, timestamp: String) async throws {
        try await queue.write { db in
            let generation = (try Int64.fetchOne(db, sql: "SELECT generation FROM unread_generations WHERE channelID = ?", arguments: [channelID])) ?? 0
            try db.execute(
                sql: """
                INSERT INTO visits(channelID, timestamp, generation) VALUES (?, ?, ?)
                ON CONFLICT(channelID) DO UPDATE SET
                    timestamp = CASE WHEN excluded.timestamp > visits.timestamp THEN excluded.timestamp ELSE visits.timestamp END,
                    generation = CASE WHEN excluded.timestamp > visits.timestamp THEN excluded.generation ELSE visits.generation END
                """,
                arguments: [channelID, timestamp, generation])
        }
    }

    /// Pending read watermarks: channel id -> newest queued timestamp.
    public func visits() async throws -> [String: String] {
        try await queue.read { db -> [String: String] in
            let channelIDs = try String.fetchAll(db, sql: "SELECT channelID FROM visits ORDER BY channelID")
            let timestamps = try String.fetchAll(db, sql: "SELECT timestamp FROM visits ORDER BY channelID")
            var result: [String: String] = [:]
            for (channelID, timestamp) in zip(channelIDs, timestamps) { result[channelID] = timestamp }
            return result
        }
    }

    public struct Visit: Sendable {
        public let channelID: String
        public let timestamp: String
        public let generation: Int64
    }
    public func visitSnapshots() async throws -> [Visit] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT channelID, timestamp, generation FROM visits").map { row in
                Visit(channelID: row["channelID"], timestamp: row["timestamp"], generation: row["generation"])
            }
        }
    }
    public func completeVisit(channelID: String, timestamp: String, generation: Int64) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM visits WHERE channelID = ? AND timestamp = ? AND generation = ?", arguments: [channelID, timestamp, generation])
        }
    }

    /// Completes a pending visit after the server accepted it. Only the exact
    /// queued watermark of the current unread generation is removed, so a
    /// stale completion can never delete a later watermark.
    public func completeVisit(channelID: String, timestamp: String) async throws {
        try await queue.write { db in
            let generation = (try Int64.fetchOne(db, sql: "SELECT generation FROM unread_generations WHERE channelID = ?", arguments: [channelID])) ?? 0
            try db.execute(
                sql: "DELETE FROM visits WHERE channelID = ? AND timestamp = ? AND generation = ?",
                arguments: [channelID, timestamp, generation])
        }
    }

    /// Explicit Mark Unread: starts a new local generation and deletes any
    /// queued visit for the channel, so a stale queued visit cannot
    /// immediately undo the unread state, and a stale completion issued
    /// before this call no longer matches any stored watermark.
    public func markUnread(channelID: String) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO unread_generations(channelID, generation) VALUES (?, 1) ON CONFLICT(channelID) DO UPDATE SET generation = generation + 1",
                arguments: [channelID])
            try db.execute(sql: "DELETE FROM visits WHERE channelID = ?", arguments: [channelID])
        }
    }

    // MARK: Internals

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func insertOperation(_ db: Database, _ operation: SendOperation) throws {
        let payload = try encode(operation)
        try db.execute(
            sql: "INSERT INTO operations(id, channelID, state, createdAt, attempts, payload) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [operation.id.uuidString, operation.channelID, operation.state.rawValue, operation.createdAt.timeIntervalSince1970, operation.attempts, payload])
    }

    private static func replaceOperation(_ db: Database, _ operation: SendOperation) throws {
        let payload = try encode(operation)
        try db.execute(
            sql: "UPDATE operations SET channelID = ?, state = ?, createdAt = ?, attempts = ?, payload = ? WHERE id = ?",
            arguments: [operation.channelID, operation.state.rawValue, operation.createdAt.timeIntervalSince1970, operation.attempts, payload, operation.id.uuidString])
    }

    private static func upsertMessage(_ db: Database, _ message: RavenMessage) throws {
        let raw = try encode(message)
        try db.execute(
            sql: "INSERT INTO messages(id, channelID, creation, owner, raw) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET channelID = excluded.channelID, creation = excluded.creation, owner = excluded.owner, raw = excluded.raw",
            arguments: [message.id, message.channelID, message.creation, message.owner, raw])
        try db.execute(sql: "DELETE FROM messages_fts WHERE id = ?", arguments: [message.id])
        try db.execute(sql: "INSERT INTO messages_fts(id, body) VALUES (?, ?)", arguments: [message.id, searchText(for: message)])
    }

    /// Plain-text index body for a message with spoiler contents masked out.
    /// If the HTML cannot be parsed, nothing is indexed (never the raw HTML,
    /// which could contain spoiler bodies).
    private static func searchText(for message: RavenMessage) -> String {
        let html = message.raw["text"].string ?? ""
        guard !html.isEmpty else { return "" }
        let bounded = String(html.prefix(Self.maxSearchableHTMLLength))
        guard let document = try? SwiftSoup.parse(bounded) else { return "" }
        _ = try? document.select("[data-spoiler]").remove()
        guard let text = try? document.text() else { return "" }
        return String(text.prefix(Self.maxSearchTextLength))
    }

    /// Enforces the bounded cache: newest `maxMessagesPerChannel` per channel
    /// and `maxMessagesTotal` overall, evicting messages and index rows alike.
    private static func trimMessages(_ db: Database) throws {
        let channelIDs = try String.fetchAll(db, sql: "SELECT DISTINCT channelID FROM messages")
        for channelID in channelIDs {
            try db.execute(
                sql: """
                DELETE FROM messages_fts WHERE id IN (
                    SELECT id FROM messages WHERE channelID = ?
                      AND id NOT IN (SELECT id FROM messages WHERE channelID = ? ORDER BY creation DESC, id DESC LIMIT ?))
                """,
                arguments: [channelID, channelID, Self.maxMessagesPerChannel])
            try db.execute(
                sql: """
                DELETE FROM messages WHERE channelID = ?
                  AND id NOT IN (SELECT id FROM messages WHERE channelID = ? ORDER BY creation DESC, id DESC LIMIT ?)
                """,
                arguments: [channelID, channelID, Self.maxMessagesPerChannel])
        }
        try db.execute(
            sql: """
            DELETE FROM messages_fts WHERE id IN (
                SELECT id FROM messages WHERE id NOT IN (SELECT id FROM messages ORDER BY creation DESC, id DESC LIMIT ?))
            """,
            arguments: [Self.maxMessagesTotal])
        try db.execute(
            sql: "DELETE FROM messages WHERE id NOT IN (SELECT id FROM messages ORDER BY creation DESC, id DESC LIMIT ?)",
            arguments: [Self.maxMessagesTotal])
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let cleaned = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
