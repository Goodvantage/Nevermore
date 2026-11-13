import Foundation
import Darwin

extension DownloadedAttachment {
    /// Publish a complete quarantined copy. File promises refuse collisions;
    /// Save As replaces only after the caller obtained the user's consent.
    /// A system-provided replacement directory keeps publication atomic on
    /// the target volume without requiring access to sibling paths.
    public func export(to destination: URL, replacing: Bool = false) throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else { throw AttachmentDownloadError.storage }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { target in
            let fm = FileManager.default
            var replacementDirectory: URL?
            defer { if let replacementDirectory { try? fm.removeItem(at: replacementDirectory) } }
            do {
                let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                replacementDirectory = directory
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let temporary = directory.appendingPathComponent("export")
                try fm.copyItem(at: url, to: temporary)
                try quarantineCopy(at: temporary)
                let handle = try FileHandle(forWritingTo: temporary)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw AttachmentDownloadError.storage }
                let flags = replacing ? UInt32(0) : UInt32(RENAME_EXCL)
                guard renamex_np(temporary.path, target.path, flags) == 0 else { throw AttachmentDownloadError.storage }
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if coordinationError != nil { throw AttachmentDownloadError.storage }
    }
}
