import Foundation

/// Which GIFs the app fetches by itself.
///
/// A GIF in a message body is an `<img>` pointing at a GIF service's media
/// host, which every reader's client loads. Loading it tells that service
/// the reader's network address and when the message was read, so the app
/// loads images automatically only from the GIF services it integrates with,
/// and only when the reader allows it (`GIFPreferences`). Any other remote
/// image stays a text fallback, like a tracking pixel would.
public enum GIFMediaPolicy {
    /// Registrable domains of the GIF services. Their media hosts are
    /// subdomains (for example `media.tenor.com`, `media2.giphy.com`).
    public static let serviceDomains = ["giphy.com", "klipy.com", "tenor.com"]
    /// GIFs are larger than link preview pictures; a long one at full size
    /// is several megabytes.
    public static let maximumMediaBytes = 12 * 1024 * 1024

    /// True for an HTTPS address on a GIF service's domain, on the default
    /// port, without credentials.
    public static func isServiceMedia(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.absoluteString.utf8.count <= LinkPreviewPolicy.maximumURLLength,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return serviceDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The address of an `<img src>` from a message body when the app may
    /// load it, else nil.
    public static func mediaURL(_ src: String) -> URL? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isServiceMedia(url) else { return nil }
        return url
    }
}

/// Loads GIF media for the transcript. `LinkPreviewLoader` is the
/// production loader; self-checks substitute a fixture.
public protocol GIFMediaLoading: Sendable {
    /// Bytes of a GIF service's media, or nil when the address is not one
    /// or the fetch failed.
    func mediaData(for url: URL) async -> Data?
}

extension LinkPreviewLoader: GIFMediaLoading {}

/// The reader's choices about GIFs, as stored in user defaults.
public enum GIFPreferences {
    /// Whether GIFs embedded in messages are loaded from GIF services.
    public static let showsInMessagesKey = "gifsInMessages"

    /// On unless the reader turned it off: GIFs are part of the
    /// conversation, and only GIF services are ever contacted.
    public static func showsInMessages(storedValue: Any?) -> Bool { (storedValue as? Bool) ?? true }
}
