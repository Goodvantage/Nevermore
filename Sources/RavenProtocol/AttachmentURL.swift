import Foundation

public enum RavenAttachmentURL {
    /// Reject missing/degenerate paths before resolving them against the site,
    /// so Space on malformed attachment metadata cannot fetch the site root.
    public static func resolve(_ value: String, origin: URL) throws -> URL {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value, relativeTo: origin)?.absoluteURL else { throw RavenError.invalidResponse }
        guard SiteOrigin.sameOrigin(url, origin) else { throw RavenError.crossOrigin }
        let path = url.standardized.path
        guard !path.isEmpty, path != "/", url.fragment == nil else { throw RavenError.invalidResponse }
        return url
    }
}
