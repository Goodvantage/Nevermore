import Foundation
import CoreServices
import Synchronization

public enum AttachmentDownloadError: LocalizedError, Sendable {
    case storage, quarantine, downloadBudget, cleanup
    public var errorDescription: String? {
        switch self {
        case .storage: return "The attachment could not be saved. Check free disk space and folder permissions, then try again."
        case .quarantine: return "The destination could not retain this download’s security metadata. Choose a different folder or disk."
        case .downloadBudget: return "Nevermore's active attachment downloads and previews have reached their limit. Close an unused attachment window or wait for a file transfer, then try again."
        case .cleanup: return "Nevermore could not remove private attachment files. Check folder permissions, then try again."
        }
    }
}

/// A complete, private, quarantined file. Retain this object for as long as a
/// preview, sharing service or file promise needs its URL. The last owner
/// removes the temporary directory; the user's exported copies are unaffected.
public final class DownloadedAttachment: Sendable {
    public let url: URL
    public let contentType: String?
    public let byteCount: Int
    private let directory: URL
    private let origin: URL
    private let lease: AttachmentDownloadLease?
    public var filename: String { url.lastPathComponent }

    init(url: URL, directory: URL, contentType: String?, byteCount: Int, origin: URL, lease: AttachmentDownloadLease? = nil) {
        self.url = url; self.directory = directory; self.contentType = contentType; self.byteCount = byteCount; self.origin = origin; self.lease = lease
    }
    deinit {
        // The shared account folder can be between a sibling download's
        // parent-directory check and child creation. Only account purge owns it.
        try? FileManager.default.removeItem(at: directory)
    }

    static func cacheDirectory(accountID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("NevermoreDownloads-\(accountID.uuidString)", isDirectory: true)
    }

    /// Remove this account's private files, including leftovers from a crash.
    /// Call only after acquiring its store lock, or closing/cancelling its UI.
    public static func purgeDownloads(accountID: UUID, in directory: URL) throws {
        guard directory.isFileURL else { throw AttachmentDownloadError.cleanup }
        let folder = cacheDirectory(accountID: accountID, in: directory)
        do { try FileManager.default.removeItem(at: folder) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
            throw AttachmentDownloadError.cleanup
        }
    }

    /// Apply security metadata to an exported copy too. Only the site's origin
    /// is recorded: bearer credentials, signed queries and private URL paths
    /// never enter exported extended attributes.
    public func quarantineCopy(at destination: URL) throws { try Self.quarantine(destination, origin: origin) }

    static func quarantine(_ destination: URL, origin: URL) throws {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.user = nil; components?.password = nil; components?.query = nil; components?.fragment = nil; components?.path = ""
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Nevermore",
            kLSQuarantineAgentBundleIdentifierKey as String: "ch.goodvantage.Nevermore",
            kLSQuarantineTimeStampKey as String: Date(),
            kLSQuarantineTypeKey as String: kLSQuarantineTypeInstantMessageAttachment as String
        ]
        if let safeOrigin = components?.url { properties[kLSQuarantineOriginURLKey as String] = safeOrigin as NSURL }
        do {
            try (destination as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
            guard try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else { throw AttachmentDownloadError.quarantine }
        }
        catch { throw AttachmentDownloadError.quarantine }
    }

    static func safeFilename(_ proposed: String) -> String {
        let last = proposed.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "attachment"
        var result = last.hasPrefix(".") ? "attachment-" : ""
        var bytes = result.utf8.count
        for character in last {
            let safe = character.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == ":" ? "_" : String($0) }.joined()
            let count = safe.utf8.count
            guard count <= 200 - bytes else { break }
            result += safe; bytes += count
        }
        return result.isEmpty ? "attachment" : result
    }
}

/// Reserve the full per-request cap before network or disk use. The lease
/// follows previews and file promises, bounding their combined live storage
/// to 512 MiB across accounts and windows, including unfinished downloads.
final class AttachmentDownloadLease: Sendable {
    private static let reserved = Mutex(0)
    private let capacity: Int
    init(maximumBytes: Int) throws {
        guard maximumBytes > 0, maximumBytes <= 512 * 1024 * 1024 else { throw AttachmentDownloadError.downloadBudget }
        try Self.reserved.withLock { used in
            guard used <= 512 * 1024 * 1024 - maximumBytes else { throw AttachmentDownloadError.downloadBudget }
            used += maximumBytes
        }
        capacity = maximumBytes
    }
    deinit { Self.reserved.withLock { $0 -= capacity } }
}
