import AppKit
import Darwin

/// A promised file delivered into a `PromisedFileBatch`'s private directory:
/// validated as a regular file whose canonical path stays inside it.
struct PromisedFile: Sendable {
    /// Canonical URL (all symlinks resolved) inside `PromisedFileBatch.directory`.
    let url: URL
    /// Last path component of `url`.
    let filename: String
    /// Byte size measured at validation time.
    let byteCount: Int64
}

/// One promised file that failed delivery or validation; the rest of the
/// batch is unaffected.
struct PromisedFileFailure: Sendable {
    /// Last path component the writer was trying to deliver, when known.
    let filename: String?
    /// Provider or validation failure description.
    let message: String
}

/// Seam between the receive engine and one pasteboard promise receiver (or a
/// scripted self-check source). `receivePromisedFiles` must invoke `reader`
/// once per produced file — on `queue` or any other queue — and return how
/// many reader callbacks the engine should expect before the batch completes.
/// Errors and cancellations are delivered through the same callback.
protocol PromisedFileSource: Sendable {
    func receivePromisedFiles(into directory: URL, on queue: OperationQueue, reader: @escaping (URL?, Error?) -> Void) -> Int
}

private struct LivePromiseSource: PromisedFileSource, @unchecked Sendable {
    let receiver: NSFilePromiseReceiver
    func receivePromisedFiles(into directory: URL, on queue: OperationQueue, reader: @escaping (URL?, Error?) -> Void) -> Int {
        receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
            reader(url, error)
        }
        // `fileNames` is empty until the promise is called in, then names every
        // file being written. The SDK contract still calls the reader once per
        // file even on failure, so expect at least one callback: providers that
        // never report names would otherwise complete with nothing received.
        return max(1, receiver.fileNames.count, receiver.fileTypes.count)
    }
}

/// Shared lifetime guard: a late callback can sweep an already-discarded batch.
private final class PromiseRegistry: @unchecked Sendable {
    static let shared = PromiseRegistry()
    private let lock = NSLock()
    private var destinations: [String: PromiseDestination] = [:]
    func add(_ destination: PromiseDestination) { lock.lock(); destinations[destination.directory.path] = destination; lock.unlock() }
    func remove(_ directory: URL) { lock.lock(); destinations.removeValue(forKey: directory.path); lock.unlock() }
    func cleanUp() { lock.lock(); let active = Array(destinations.values); destinations.removeAll(); lock.unlock(); for destination in active { destination.discard() } }
}

fileprivate final class PromiseDestination: @unchecked Sendable {
    let directory: URL
    let providerDirectory: URL
    let snapshots: URL
    private let lock = NSLock()
    private var discarded = false
    let grace: TimeInterval
    init(directory: URL, grace: TimeInterval) {
        self.directory = directory; self.grace = grace
        providerDirectory = directory.appendingPathComponent("Provider", isDirectory: true)
        snapshots = directory.appendingPathComponent("Accepted", isDirectory: true)
    }
    func discard() {
        lock.lock(); let first = !discarded; discarded = true; lock.unlock()
        PromiseRegistry.shared.remove(directory)
        try? FileManager.default.removeItem(at: directory)
        if first && grace > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [directory] in try? FileManager.default.removeItem(at: directory) } }
    }
    func sweepIfDiscarded() {
        lock.lock(); let shouldRemove = discarded; lock.unlock()
        if shouldRemove { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Contains immutable private snapshots, not mutable paths owned by a provider.
final class PromisedFileBatch: @unchecked Sendable {
    let directory: URL
    let files: [PromisedFile]
    let failures: [PromisedFileFailure]
    let droppedFailures: Int
    let timedOut: Bool
    var urls: [URL] { files.map(\.url) }
    private let destination: PromiseDestination
    fileprivate init(destination: PromiseDestination, files: [PromisedFile], failures: [PromisedFileFailure], droppedFailures: Int, timedOut: Bool) {
        self.destination = destination; directory = destination.directory; self.files = files; self.failures = failures; self.droppedFailures = droppedFailures; self.timedOut = timedOut
    }
    func cleanup() { destination.discard() }
    deinit { cleanup() }
}

/// Receives incoming file promises (Finder drags, promised attachments) into a
/// unique private directory inside the app's temporary directory, and returns
/// a bounded batch the caller stages into `AccountStore` and then cleans up.
///
/// Usage from a drop or paste handler:
///   guard PromisedFileReceiver.containsPromises(pasteboard) else { return false }
///   let batch = try await PromisedFileReceiver.receive(pasteboard)
///   for url in batch.urls { try await session.store.stage(file: url) }
///   batch.cleanup()
///
/// Callbacks may arrive on an arbitrary queue, in any order, and more than
/// once; the engine deduplicates by canonical path and discards anything that
/// arrives after completion, cancellation or the timeout. Nothing here reads
/// pasteboard HTML or file contents — it only returns local file URLs.
enum PromisedFileReceiver {
    /// Bounds for one receive operation.
    struct Limits: Sendable {
        /// Accepted-files cap; extra files fail and are deleted.
        var maxFiles: Int
        /// Receivers-per-pasteboard cap; over it the receive throws.
        var maxSources: Int
        /// Total accepted-bytes cap; files past the cap fail and are deleted.
        /// Matches `AccountStore.defaultMaxStagingBytes`.
        var maxBytes: Int64
        /// Stored-failures cap; extras only bump `droppedFailures`.
        var maxFailures: Int
        /// Deadline for all promised callbacks.
        var timeout: TimeInterval
        /// After a timeout/cancel cleanup, the destination is removed once
        /// more after this delay so late writes cannot leave stray files.
        var lateWriteGrace: TimeInterval
        init(maxFiles: Int = 32, maxSources: Int = 128, maxBytes: Int64 = 256 * 1024 * 1024, maxFailures: Int = 64, timeout: TimeInterval = 60, lateWriteGrace: TimeInterval = 15) {
            self.maxFiles = maxFiles; self.maxSources = maxSources; self.maxBytes = maxBytes
            self.maxFailures = maxFailures; self.timeout = timeout; self.lateWriteGrace = lateWriteGrace
        }
    }

    /// Drag types a view must register to be offered promised files:
    /// `view.registerForDraggedTypes(PromisedFileReceiver.draggedTypes)`.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Whether the pasteboard declares any type `NSFilePromiseReceiver` reads,
    /// or the legacy `kPasteboardTypeFileURLPromise` type.
    @MainActor static func containsPromises(_ pasteboard: NSPasteboard) -> Bool {
        var readable = Set(NSFilePromiseReceiver.readableDraggedTypes)
        readable.insert("com.apple.pasteboard.promised-file-url")
        return (pasteboard.types ?? []).contains { readable.contains($0.rawValue) }
    }

    /// Snapshot the receivers during the drop/paste event; never reread a changed pasteboard later.
    @MainActor static func sources(from pasteboard: NSPasteboard) -> [any PromisedFileSource] {
        ((pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []).map { LivePromiseSource(receiver: $0) }
    }

    static func cleanUpActiveReceives() { PromiseRegistry.shared.cleanUp() }
    static func cleanUpAbandonedReceives() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let prefix = "NevermorePromisedFiles-"
        for directory in entries where directory.lastPathComponent.hasPrefix(prefix) {
            guard UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
                  let attrs = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), attrs.isDirectory == true, attrs.isSymbolicLink != true else { continue }
            let marker = directory.appendingPathComponent(".nevermore-owner")
            guard let metadata = try? marker.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]), metadata.isRegularFile == true, metadata.isSymbolicLink != true, (metadata.fileSize ?? 1024) <= 64,
                  let data = try? Data(contentsOf: marker), let text = String(data: data, encoding: .utf8), text.hasPrefix("v1:"),
                  let process = Int32(text.dropFirst(3)), process > 1, Darwin.kill(process, 0) != 0, errno == ESRCH else { continue }
            try? fm.removeItem(at: directory)
        }
    }

    /// Reads all promise receivers off the pasteboard and collects their
    /// files. Call from the actor handling the drop or paste.
    @MainActor static func receive(_ pasteboard: NSPasteboard, limits: Limits = Limits()) async throws -> PromisedFileBatch {
        return try await receive(sources: sources(from: pasteboard), limits: limits)
    }

    /// The receive engine, driven by `PromisedFileSource` so self-checks can
    /// script delivery deterministically without Finder.
    static func receive(sources: [any PromisedFileSource], limits: Limits = Limits()) async throws -> PromisedFileBatch {
        try Task.checkCancellation()
        guard !sources.isEmpty, limits.maxSources > 0, sources.count <= min(128, limits.maxSources),
              (0...1024).contains(limits.maxFiles), limits.maxBytes >= 0, (0...1024).contains(limits.maxFailures),
              limits.timeout.isFinite, limits.timeout > 0, limits.lateWriteGrace.isFinite, limits.lateWriteGrace >= 0 else { throw AppError.message("Invalid or excessive promised-file batch.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermorePromisedFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = PromiseDestination(directory: root.resolvingSymlinksInPath(), grace: limits.lateWriteGrace)
        do { try FileManager.default.createDirectory(at: destination.providerDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { destination.discard(); throw error }
        do { try Data("v1:\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: destination.directory.appendingPathComponent(".nevermore-owner"), options: .atomic) }
        catch { destination.discard(); throw error }
        PromiseRegistry.shared.add(destination)
        let collector = Collector(destination: destination, limits: limits)
        DispatchQueue.global().asyncAfter(deadline: .now() + limits.timeout) { collector.finish(.timeout) }
        let batch: PromisedFileBatch = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in collector.install(continuation); collector.start(sources) }
        } onCancel: { collector.finish(.cancelled) }
        do { try Task.checkCancellation(); return batch } catch { batch.cleanup(); throw error }
    }
}

/// State is locked briefly; copying is outside that lock so cancellation does not block UI.
private final class Collector: @unchecked Sendable {
    enum FinishReason { case complete, timeout, cancelled, limited }
    let limits: PromisedFileReceiver.Limits
    let destination: PromiseDestination
    private let lock = NSLock()
    private let copying = NSLock()
    private var expected = 0
    private var delivered = 0
    private var started = false
    private var finished = false
    private var seen = Set<String>()
    private var files: [PromisedFile] = []
    private var failures: [PromisedFileFailure] = []
    private var droppedFailures = 0
    private var totalBytes: Int64 = 0
    private var continuation: CheckedContinuation<PromisedFileBatch, Error>?
    private var pending: Result<PromisedFileBatch, Error>?
    init(destination: PromiseDestination, limits: PromisedFileReceiver.Limits) { self.destination = destination; self.limits = limits }
    func install(_ continuation: CheckedContinuation<PromisedFileBatch, Error>) {
        lock.lock()
        if let pending { self.pending = nil; lock.unlock(); continuation.resume(with: pending) }
        else { self.continuation = continuation; lock.unlock() }
    }
    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func start(_ sources: [any PromisedFileSource]) {
        let queue = OperationQueue(); queue.name = "ch.goodvantage.Nevermore.promised-files"; queue.maxConcurrentOperationCount = 1
        var total = 0
        for (index, source) in sources.enumerated() {
            guard !isFinished else { break }
            // AppKit requires every receiver in one drag to use the SAME destination.
            let count = source.receivePromisedFiles(into: destination.providerDirectory, on: queue) { [self] url, error in record(source: index, url: url, error: error) }
            if count > 4096 || total > 4096 - max(0, count) { finish(.limited); return }
            total += max(0, count)
        }
        lock.lock(); expected = total; started = true; let complete = !finished && delivered >= expected; lock.unlock()
        if complete { finish(.complete) }
    }
    func record(source: Int, url: URL?, error: Error?) {
        // Snapshot synchronously INSIDE the SDK reader's coordinated read. All
        // live readers are on a serial OperationQueue; this also serializes bad providers.
        copying.lock(); defer { copying.unlock() }
        lock.lock()
        guard !finished else { lock.unlock(); destination.sweepIfDiscarded(); return }
        let key = "\(source):" + (url?.standardized.absoluteString ?? "unknown-error")
        guard seen.insert(key).inserted else { lock.unlock(); return }
        if seen.count > min(512, limits.maxFiles + limits.maxFailures + limits.maxSources) { lock.unlock(); finish(.limited); return }
        let remaining = limits.maxBytes - totalBytes
        let countAllowed = files.count < limits.maxFiles
        lock.unlock()
        var accepted: SecurePromisedInput.Snapshot?
        var failure: String?
        if let error { failure = error.localizedDescription }
        else if let url {
            do {
                guard countAllowed else { throw AppError.message("Too many promised files.") }
                accepted = try SecurePromisedInput.copy(url, beneath: destination.providerDirectory, into: destination.snapshots, maxBytes: remaining, isCancelled: { [self] in isFinished })
            } catch { failure = error.localizedDescription; SecurePromisedInput.discard(url, beneath: destination.providerDirectory) }
        } else { failure = "The file provider returned no file." }
        lock.lock()
        guard !finished else { lock.unlock(); if let accepted { try? FileManager.default.removeItem(at: accepted.url.deletingLastPathComponent()) }; destination.sweepIfDiscarded(); return }
        delivered += 1
        if let accepted { totalBytes += accepted.byteCount; files.append(PromisedFile(url: accepted.url, filename: accepted.url.lastPathComponent, byteCount: accepted.byteCount)) }
        if let failure { if failures.count < limits.maxFailures { failures.append(PromisedFileFailure(filename: url?.lastPathComponent, message: failure)) } else { droppedFailures += 1 } }
        let complete = started && delivered >= expected
        lock.unlock()
        if complete { finish(.complete) }
    }
    func finish(_ reason: FinishReason) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        if reason == .limited {
            if failures.count < limits.maxFailures { failures.append(PromisedFileFailure(filename: nil, message: "The file provider returned too many files.")) } else { droppedFailures += 1 }
        }
        let batch = reason == .cancelled ? nil : PromisedFileBatch(destination: destination, files: files, failures: failures, droppedFailures: droppedFailures, timedOut: reason == .timeout)
        lock.unlock()
        if let batch { complete(.success(batch)) }
        else {
            // A provider can still be writing. Cancel fast, clean off the main thread,
            // then resume; later callbacks sweep again after ownership was discarded.
            DispatchQueue.global().async { [self] in destination.discard(); complete(.failure(CancellationError())) }
        }
    }
    private func complete(_ result: Result<PromisedFileBatch, Error>) {
        lock.lock()
        if let continuation { self.continuation = nil; lock.unlock(); continuation.resume(with: result) }
        else { pending = result; lock.unlock() }
    }
}
