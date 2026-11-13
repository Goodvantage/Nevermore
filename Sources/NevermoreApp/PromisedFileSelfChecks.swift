import AppKit

@MainActor enum PromisedFileSelfChecks {
    /// Deterministic checks for `PromisedFileReceiver`, driven by scripted
    /// `PromisedFileSource`s — no Finder automation or real drags involved.
    static func run() async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ condition: Bool, _ label: String) { results.append((label, condition)) }
        let fm = FileManager.default
        func inside(_ file: PromisedFile, _ directory: URL) -> Bool {
            file.url.path.hasPrefix(directory.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }

        // Pasteboard detection on a private pasteboard; no data is needed.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NevermorePromisedFileCheck-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let cleanBefore = !PromisedFileReceiver.containsPromises(pasteboard)
        // The types a real file-promise drag declares; the content type is in
        // `NSFilePromiseReceiver.readableDraggedTypes` (verified against the
        // local SDK). No item data is needed for detection.
        pasteboard.declareTypes([NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"), NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")], owner: nil)
        check(cleanBefore && PromisedFileReceiver.containsPromises(pasteboard) && !PromisedFileReceiver.draggedTypes.isEmpty, "file promises are detected only on pasteboards that declare them")
        do {
            let batch = try await PromisedFileReceiver.receive(pasteboard, limits: .init(timeout: 2))
            check(batch.files.isEmpty, "a promise pasteboard without real receivers yields no files")
        } catch {
            check(true, "a promise pasteboard without real receivers fails to start")
        }

        // Success across multiple sources; one delivers on the operation queue.
        let successCapture = SourceCapture()
        let success = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 2) { directory, _, reader in
                successCapture.reader = reader
                write(3, directory.appendingPathComponent("one.txt"))
                reader(directory.appendingPathComponent("one.txt"), nil)
                write(4, directory.appendingPathComponent("two.txt"))
                reader(directory.appendingPathComponent("two.txt"), nil)
            },
            ScriptedSource(expected: 1) { directory, queue, reader in
                successCapture.reader = reader
                queue.addOperation {
                    write(5, directory.appendingPathComponent("three.txt"))
                    successCapture.reader?(directory.appendingPathComponent("three.txt"), nil)
                }
            },
        ])
        check(success.files.count == 3 && !success.timedOut && success.failures.isEmpty && success.files.allSatisfy { inside($0, success.directory) } && success.files.map(\.byteCount) == [3, 4, 5], "multiple receivers deliver into one private directory")

        // A callback delivered after the batch formed is discarded, and files
        // it wrote are removed by cleanup.
        let late = success.directory.appendingPathComponent("late.txt")
        write(1, late)
        successCapture.reader?(late, nil)
        check(success.files.count == 3, "callbacks arriving after completion are discarded")
        success.cleanup()
        check(!fm.fileExists(atPath: success.directory.path) && !fm.fileExists(atPath: late.path), "cleanup removes the private directory including stray files")

        // Partial failure: one file delivered, one provider error.
        let partial = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 2) { directory, _, reader in
                write(6, directory.appendingPathComponent("kept.txt"))
                reader(directory.appendingPathComponent("kept.txt"), nil)
                reader(directory.appendingPathComponent("lost.txt"), NSError(domain: "NevermoreSelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "scripted provider failure"]))
            },
        ])
        check(partial.files.count == 1 && partial.files[0].filename == "kept.txt" && partial.failures.count == 1 && !partial.timedOut, "a failed promised file does not block the others")
        partial.cleanup()

        // Duplicate callbacks and out-of-destination files.
        let outsideDirectory = fm.temporaryDirectory.appendingPathComponent("NevermorePromisedFileOutside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideFile = outsideDirectory.appendingPathComponent("outside.txt")
        write(7, outsideFile)
        let dedup = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 2) { directory, _, reader in
                let file = directory.appendingPathComponent("same.txt")
                write(8, file)
                reader(file, nil)
                reader(file, nil)
                reader(outsideFile, nil)
            },
        ])
        check(dedup.files.count == 1 && dedup.failures.count == 1 && fm.fileExists(atPath: outsideFile.path), "duplicate callbacks and out-of-destination files are dropped without touching the outside file")
        dedup.cleanup()

        // A symlink inside the destination resolving outside it is rejected.
        let escaped = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 1) { directory, _, reader in
                let link = directory.appendingPathComponent("link.txt")
                try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outsideFile.path)
                reader(link, nil)
            },
        ])
        check(escaped.files.isEmpty && escaped.failures.count == 1 && fm.fileExists(atPath: outsideFile.path), "symlinks escaping the private destination are rejected")
        escaped.cleanup()

        // Directories are not promised files.
        let notFile = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 1) { directory, _, reader in
                let sub = directory.appendingPathComponent("nested", isDirectory: true)
                try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                reader(sub, nil)
            },
        ])
        check(notFile.files.isEmpty && notFile.failures.count == 1, "directories are rejected as promised files")
        notFile.cleanup()

        // Count bound: the overflow file is rejected and removed.
        let capped = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 3) { directory, _, reader in
                for name in ["a.txt", "b.txt", "c.txt"] { write(2, directory.appendingPathComponent(name)); reader(directory.appendingPathComponent(name), nil) }
            },
        ], limits: .init(maxFiles: 2))
        check(capped.files.count == 2 && capped.failures.count == 1 && !fm.fileExists(atPath: capped.directory.appendingPathComponent("c.txt").path), "the file count bound rejects and removes overflow files")
        capped.cleanup()

        // Byte bound: the oversized file is rejected and removed.
        let bounded = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 2) { directory, _, reader in
                let small = directory.appendingPathComponent("small.txt"), big = directory.appendingPathComponent("big.txt")
                write(8, small); reader(small, nil)
                write(20, big); reader(big, nil)
            },
        ], limits: .init(maxBytes: 10))
        check(bounded.files.count == 1 && bounded.files[0].byteCount == 8 && bounded.failures.count == 1 && !fm.fileExists(atPath: bounded.directory.appendingPathComponent("big.txt").path), "the byte bound rejects and removes oversized promised files")
        bounded.cleanup()

        // Timeout: the partial batch is returned; the deferred sweep removes
        // files a provider writes after cleanup.
        let timed = try await PromisedFileReceiver.receive(sources: [
            ScriptedSource(expected: 2) { directory, _, reader in
                write(9, directory.appendingPathComponent("early.txt"))
                reader(directory.appendingPathComponent("early.txt"), nil)
            },
        ], limits: .init(timeout: 0.25, lateWriteGrace: 0.4))
        check(timed.timedOut && timed.files.count == 1 && timed.files[0].filename == "early.txt", "timeout returns the partial batch with what arrived")
        timed.cleanup()
        try fm.createDirectory(at: timed.directory, withIntermediateDirectories: true)
        write(1, timed.directory.appendingPathComponent("straggler.txt"))
        try await Task.sleep(for: .milliseconds(700))
        check(!fm.fileExists(atPath: timed.directory.path), "the deferred sweep removes files written after cleanup")

        // Cancellation: pending receive throws CancellationError, the private
        // directory is removed, and late callbacks are discarded.
        let capture = SourceCapture()
        let task = Task {
            try await PromisedFileReceiver.receive(sources: [
                ScriptedSource(expected: 1) { directory, _, reader in capture.directory = directory; capture.reader = reader },
            ], limits: .init(timeout: 120, lateWriteGrace: 0.1))
        }
        for _ in 0..<200 { if capture.directory != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do { _ = try await task.value; check(false, "cancelling a pending receive throws CancellationError") }
        catch is CancellationError { check(true, "cancelling a pending receive throws CancellationError") }
        catch { check(false, "cancelling a pending receive throws CancellationError") }
        check(capture.directory.map { !fm.fileExists(atPath: $0.path) } == true, "cancelled receive removes its private directory")
        capture.reader?(capture.directory?.appendingPathComponent("after-cancel.txt"), nil)
        check(capture.directory.map { !fm.fileExists(atPath: $0.path) } == true, "callbacks arriving after cancellation are discarded")

        // Cleanup of the out-of-destination fixture.
        try? fm.removeItem(at: outsideDirectory)
        return results
    }
}

/// File-scope fixture writer: unconditionally `Sendable` for script closures.
private func write(_ bytes: Int, _ url: URL) { try! Data(repeating: 0x61, count: bytes).write(to: url) }

/// Mutable capture handed to a scripted source; `Sendable` so the source may
/// keep it for post-cancellation callbacks.
private final class SourceCapture: @unchecked Sendable {
    var directory: URL?
    var reader: ((URL?, Error?) -> Void)?
}

/// Scripted `PromisedFileSource`: writes real files into the destination and
/// invokes the reader a controlled number of times — inline or on `queue`.
private struct ScriptedSource: PromisedFileSource {
    let expected: Int
    let script: @Sendable (URL, OperationQueue, @escaping (URL?, Error?) -> Void) -> Void
    init(expected: Int, script: @escaping @Sendable (URL, OperationQueue, @escaping (URL?, Error?) -> Void) -> Void) {
        self.expected = expected
        self.script = script
    }
    func receivePromisedFiles(into directory: URL, on queue: OperationQueue, reader: @escaping (URL?, Error?) -> Void) -> Int {
        script(directory, queue, reader)
        return expected
    }
}
