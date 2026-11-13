import Foundation

/// Canonical network origin for a Frappe site: scheme + host + optional port.
/// An origin is never the Frappe sitename, workspace, or display name.
public enum SiteOrigin {
    /// Normalizes user input into an `https://host[:port]` origin URL.
    /// Rejects credentials, paths, queries, fragments, and non-HTTPS schemes.
    /// `allowLocalHTTP` permits plain HTTP only for loopback development sites.
    public static func normalize(_ input: String, allowLocalHTTP: Bool = false) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048, !text.contains(" ") else { throw RavenError.invalidSite }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { throw RavenError.invalidSite }
        guard components.user == nil, components.password == nil else { throw RavenError.invalidSite }
        let path = components.percentEncodedPath
        guard (path.isEmpty || path == "/"), components.query == nil, components.fragment == nil else { throw RavenError.invalidSite }
        if scheme == "http" {
            guard allowLocalHTTP, Self.isLoopback(host) else { throw RavenError.invalidSite }
        } else {
            guard scheme == "https" else { throw RavenError.invalidSite }
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port, port != Self.defaultPort(scheme) { origin += ":\(port)" }
        guard let url = URL(string: origin) else { throw RavenError.invalidSite }
        return url
    }

    /// Scheme/host/effective-port equality. `https://a.example` equals
    /// `https://a.example:443`; different schemes, hosts, or ports differ.
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard a.user == nil, a.password == nil, b.user == nil, b.password == nil,
              let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(), schemeA == schemeB,
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased(), hostA == hostB else { return false }
        return Self.port(a) == Self.port(b)
    }

    static func port(_ url: URL) -> Int? {
        url.port ?? url.scheme.flatMap { defaultPort($0.lowercased()) }
    }

    static func defaultPort(_ scheme: String) -> Int? {
        switch scheme { case "https": return 443; case "http": return 80; default: return nil }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
