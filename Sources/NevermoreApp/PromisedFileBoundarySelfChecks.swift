import AppKit
import NevermoreCore

private final class PromiseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDirectory: URL?
    private var storedReader: ((URL?, Error?) -> Void)?
    var directory: URL? { lock.lock(); defer { lock.unlock() }; return storedDirectory }
    func store(_ directory: URL, _ reader: @escaping (URL?, Error?) -> Void) { lock.lock(); storedDirectory = directory; storedReader = reader; lock.unlock() }
    func deliver(_ url: URL?, error: Error? = nil) { lock.lock(); let reader = storedReader; lock.unlock(); reader?(url, error) }
}
private struct BoundaryPromiseSource: PromisedFileSource {
    let script: @Sendable (URL, OperationQueue, @escaping (URL?, Error?) -> Void) -> Int
    func receivePromisedFiles(into directory: URL, on queue: OperationQueue, reader: @escaping (URL?, Error?) -> Void) -> Int { script(directory, queue, reader) }
}
@MainActor enum PromisedFileBoundarySelfChecks {
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let duplicate = PromiseCapture()
        let complete = try await PromisedFileReceiver.receive(sources: [BoundaryPromiseSource { directory, queue, reader in
            let first = directory.appendingPathComponent("first.txt")
            try! Data("first".utf8).write(to: first); reader(first, nil); reader(first, nil)
            duplicate.store(directory, reader)
            queue.addOperation { let last = directory.appendingPathComponent("last.txt"); try! Data("last".utf8).write(to: last); duplicate.deliver(last) }
            return 2
        }], limits: .init(timeout: 2))
        results.append(("duplicate callbacks cannot finish a file promise before another file arrives", complete.files.count == 2 && !complete.timedOut && Set(complete.files.map(\.filename)) == ["first.txt", "last.txt"]))
        complete.cleanup()
        let one = PromiseCapture(), two = PromiseCapture()
        let sameName = try await PromisedFileReceiver.receive(sources: [
            BoundaryPromiseSource { directory, _, reader in one.store(directory, reader); let file = directory.appendingPathComponent("same.txt"); try! Data("one".utf8).write(to: file); reader(file, nil); return 1 },
            BoundaryPromiseSource { directory, _, reader in two.store(directory, reader); let file = directory.appendingPathComponent("same.txt"); try! Data("two".utf8).write(to: file); reader(file, nil); return 1 }
        ])
        let contents = try sameName.files.map { String(decoding: try Data(contentsOf: $0.url), as: UTF8.self) }
        results.append(("same-name promised files use one SDK destination and retain independent snapshots", one.directory == two.directory && contents == ["one", "two"] && sameName.files[0].url != sameName.files[1].url))
        sameName.cleanup()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("NevermorePromiseOutside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("outside.txt"); try Data("must-never-stage".utf8).write(to: secret)
        let swapped = try await PromisedFileReceiver.receive(sources: [BoundaryPromiseSource { directory, _, reader in
            let file = directory.appendingPathComponent("safe.txt"); try! Data("safe original".utf8).write(to: file)
            reader(file, nil)
            try! FileManager.default.removeItem(at: file); try! FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
            return 1
        }])
        let swappedText = try swapped.files.first.map { String(decoding: try Data(contentsOf: $0.url), as: UTF8.self) }
        results.append(("a provider cannot replace validated output with a symlink before staging", swapped.files.count == 1 && swappedText == "safe original"))
        swapped.cleanup()
        let escaped = try await PromisedFileReceiver.receive(sources: [BoundaryPromiseSource { directory, _, reader in
            let nested = directory.appendingPathComponent("nested")
            try! FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside); reader(nested.appendingPathComponent("outside.txt"), nil); return 1
        }])
        results.append(("promise snapshots refuse symlinks in every path component", escaped.files.isEmpty && escaped.failures.count == 1 && FileManager.default.fileExists(atPath: secret.path)))
        escaped.cleanup()
        let late = PromiseCapture()
        let released = try await PromisedFileReceiver.receive(sources: [BoundaryPromiseSource { directory, _, reader in
            late.store(directory, reader); let file = directory.appendingPathComponent("done.txt"); try! Data("done".utf8).write(to: file); reader(file, nil); return 1
        }], limits: .init(lateWriteGrace: 0))
        released.cleanup()
        if let directory = late.directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let file = directory.appendingPathComponent("late.txt"); try Data("late".utf8).write(to: file); late.deliver(file) }
        results.append(("late callbacks sweep discarded destinations even after a grace timer", !FileManager.default.fileExists(atPath: released.directory.path)))
        guard let session = owner.session, let channel = owner.channel else { return results + [("promise integration has an account", false)] }
        let delivered = PromiseCapture()
        owner.receivePromisedFiles([BoundaryPromiseSource { directory, _, reader in
            delivered.store(directory, reader); let file = directory.appendingPathComponent("promise-draft.txt"); try! Data("private staged input".utf8).write(to: file); reader(file, nil); return 1
        }])
        await owner.waitForPromisedFiles(); await owner.saveTask?.value
        let draft = try await session.store.draft(channelID: channel.id)
        let staged = draft?.attachments.first { $0.filename == "promise-draft.txt" }
        results.append(("promised files persist only as private durable draft attachments", staged != nil && staged?.localPath.contains("NevermorePromisedFiles-") == false && delivered.directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true))
        owner.clearAttachments(); await owner.saveTask?.value
        owner.receivePromisedFiles([BoundaryPromiseSource { _, _, reader in reader(nil, NSError(domain: "NevermoreFixture", code: 1)); return 1 }])
        await owner.waitForPromisedFiles(); await owner.saveTask?.value
        results.append(("file-provider failures remain visible after shared-session refresh", owner.status.stringValue.contains("could not be received") && owner.attachments.isEmpty))
        let pending = PromiseCapture()
        owner.receivePromisedFiles([BoundaryPromiseSource { directory, _, reader in pending.store(directory, reader); return 1 }])
        for _ in 0..<100 { if pending.directory != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        let receiving = Array(owner.promisedReceives.values)
        owner.use(nil)
        for task in receiving { await task.value }
        results.append(("account switching cancels pending promises without attaching them elsewhere", owner.session == nil && owner.attachments.isEmpty && pending.directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true))
        owner.use(session); owner.select(channel); await owner.loadTask?.value; await owner.renderTask?.value
        return results
    }
}
