import Foundation
import Darwin

/// Snapshots only regular files opened beneath the granted promise destination.
/// No path component may be a symlink; the private copy is never a provider path.
enum SecurePromisedInput {
    struct Snapshot: Sendable { let url: URL; let byteCount: Int64 }
    /// Unlink only an entry beneath the destination, through non-followed directory descriptors.
    static func discard(_ input: URL, beneath destination: URL) {
        guard input.isFileURL else { return }
        let path = input.standardizedFileURL.path
        let roots = [destination.standardizedFileURL.path, destination.standardizedFileURL.resolvingSymlinksInPath().path]
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return }
        let parts = String(path.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else { return }
        var parent = Darwin.open(destination.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return }; defer { Darwin.close(parent) }
        for part in parts.dropLast() {
            let next = Darwin.openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return }; Darwin.close(parent); parent = next
        }
        _ = Darwin.unlinkat(parent, parts.last!, 0)
    }

    static func copy(_ input: URL, beneath destination: URL, into snapshots: URL, maxBytes: Int64, isCancelled: @Sendable () -> Bool = { false }) throws -> Snapshot {
        guard input.isFileURL, maxBytes >= 0 else { throw AppError.message("Invalid promised file.") }
        let literal = input.standardizedFileURL.path
        let roots = [destination.standardizedFileURL.path, destination.standardizedFileURL.resolvingSymlinksInPath().path]
        guard let root = roots.first(where: { literal.hasPrefix($0 + "/") }) else { throw AppError.message("Promised file escaped its destination.") }
        let components = String(literal.dropFirst(root.count + 1)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else { throw AppError.message("Invalid promised filename.") }
        let canonicalRoot = destination.standardizedFileURL.path
        var directoryFD = Darwin.open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw AppError.message("Promised file destination is unavailable.") }
        defer { Darwin.close(directoryFD) }
        for component in components.dropLast() {
            let next = Darwin.openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw AppError.message("Promised file contains an unsafe directory link.") }
            Darwin.close(directoryFD); directoryFD = next
        }
        let sourceFD = Darwin.openat(directoryFD, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { throw AppError.message("Promised file could not be opened safely.") }
        defer { Darwin.close(sourceFD) }
        var before = stat()
        guard fstat(sourceFD, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1, before.st_size >= 0 else { throw AppError.message("Promised output is not a private regular file.") }
        guard before.st_size <= maxBytes else { throw AppError.message("Promised files exceed the attachment budget.") }
        if isCancelled() { throw CancellationError() }
        let folder = snapshots.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent(components.last!)
        let targetFD = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard targetFD >= 0 else { try? FileManager.default.removeItem(at: folder); throw AppError.message("Could not snapshot the promised file.") }
        defer { Darwin.close(targetFD) }
        do {
            var bytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                if isCancelled() { throw CancellationError() }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw AppError.message("Could not read the promised file.") }
                if count == 0 { break }
                guard Int64(count) <= maxBytes - bytes else { throw AppError.message("Promised file grew beyond the attachment budget.") }
                try buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < count {
                        let wrote = Darwin.write(targetFD, raw.baseAddress!.advanced(by: offset), count - offset)
                        if wrote < 0 && errno == EINTR { continue }
                        guard wrote > 0 else { throw AppError.message("Could not save the promised file snapshot.") }
                        offset += wrote
                    }
                }
                bytes += Int64(count)
            }
            var after = stat()
            guard fstat(sourceFD, &after) == 0, bytes == before.st_size, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw AppError.message("Promised file changed while it was being received. Try attaching it again.") }
            return Snapshot(url: target, byteCount: bytes)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
