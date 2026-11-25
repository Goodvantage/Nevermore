import Foundation
import SwiftSoup

/// The content of a link preview card, detached from any network or UI.
///
/// The loader only produces values for an address that passed
/// `LinkPreviewPolicy.isEligible` and whose host, like that of every
/// redirect on the way, resolved to public addresses only. The text
/// fields are plain text, cleaned by `LinkPreviewParser`.
public struct LinkPreview: Sendable, Equatable {
    /// The address the preview was requested for.
    public var url: URL
    public var title: String
    /// May be empty.
    public var summary: String
    /// `og:site_name`, or the final host without a leading "www.".
    public var siteName: String
    /// An https image that passed `LinkPreviewPolicy.isEligible`.
    public var imageURL: URL?
    /// The image's size in pixels as the server measured it, when it did.
    /// It places the picture before the image arrives.
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    public init(url: URL, title: String, summary: String, siteName: String, imageURL: URL?, imagePixelWidth: Int? = nil, imagePixelHeight: Int? = nil) {
        self.url = url
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageURL = imageURL
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
    }
}

/// Rules that decide whether an address may be fetched at all.
///
/// A link preview is fetched by the app itself, from an address that may
/// have been pasted from a hostile source. Every rule below exists so
/// that a pasted link cannot make the app talk to the local network, to
/// a plain-text endpoint, or to an odd port.
public enum LinkPreviewPolicy: Sendable {
    /// Caps keep a hostile page from exhausting memory or the card. The
    /// transfer normally ends at `</head>`, long before the cap; some
    /// large sites only reach their title after several hundred kilobytes
    /// of inline script. Raven's own preview fetcher reads up to 2 MB too.
    public static let maximumHTMLBytes = 2 * 1024 * 1024
    public static let maximumImageBytes = 2 * 1024 * 1024
    /// A redirect chain is a classic way to bounce a checked fetcher into
    /// the local network afterwards.
    public static let maximumRedirects = 5
    /// The longest silence the fetcher waits through.
    public static let requestTimeout: TimeInterval = 8
    /// The longest one request may take in total, so a page that trickles
    /// bytes cannot hold a connection open.
    public static let transferTimeout: TimeInterval = 20
    public static let maximumURLLength = 2048
    public static let maximumTitleLength = 140
    public static let maximumSummaryLength = 280

    /// Site names are short labels; the cap keeps a hostile page from
    /// filling the card.
    static let maximumSiteNameLength = 60

    public enum Address: Sendable, Equatable {
        case v4(UInt8, UInt8, UInt8, UInt8)
        /// 16 bytes, network order.
        case v6([UInt8])
    }

    /// Names that a resolver answers from the local network by
    /// convention. They look like DNS names but are never public.
    private static let blockedHostSuffixes = [
        ".localhost",
        ".local",
        ".internal",
        ".lan",
        ".home",
        ".home.arpa",
        ".corp",
        ".intranet",
        ".private",
        ".test",
        ".invalid",
        ".onion",
    ]

    /// Lexical test of an address before any network use.
    public static func isEligible(_ url: URL) -> Bool {
        // Plaintext endpoints are never fetched.
        guard url.scheme?.lowercased() == "https" else { return false }
        // Credentials in the address are a phishing pattern and would
        // have to be stripped or leaked to fetch.
        guard url.user == nil, url.password == nil else { return false }
        // A long address is hard to review and easy to use as a payload.
        guard url.absoluteString.utf16.count <= maximumURLLength else { return false }
        // An odd port is usually a private service; only the default TLS
        // port is allowed.
        guard url.port == nil || url.port == 443 else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        // IP literals skip the DNS-name rules below and are the most
        // direct route to a private address.
        guard !host.contains(":"), !host.contains("["), !host.contains("]") else { return false }
        guard !isIPLiteral(host) else { return false }
        // A DNS name has at least one dot and a TLD-like last label.
        guard host.contains(".") else { return false }
        var normalizedHost = host
        if normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }
        let labels = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard let lastLabel = labels.last, lastLabel.count >= 2 else { return false }
        // Numeric-only labels are IP-literal spellings such as "1".
        guard !lastLabel.allSatisfy({ $0.isNumber }) else { return false }
        guard lastLabel.filter({ $0.isLetter }).count >= 2 else { return false }
        // Local-network names that would resolve inside the user's LAN.
        guard normalizedHost != "localhost" else { return false }
        for suffix in blockedHostSuffixes where normalizedHost.hasSuffix(suffix) {
            return false
        }
        return true
    }

    /// True for the IPv4 spellings browsers accept as an address:
    /// dotted quads, short forms such as "0x7f.1", and bare integers such
    /// as "2130706433".
    private static func isIPLiteral(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ isIntegerLiteral(String($0)) }) else { return false }
        // One to four numeric labels are an IPv4 literal in some form.
        return (1...4).contains(labels.count)
    }

    private static func isIntegerLiteral(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            let digits = text.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy { $0.isHexDigit }
        }
        return text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether a resolved address is on the public internet.
    ///
    /// Private, loopback, link-local, benchmark, documentation and
    /// multicast ranges are answers from inside the user's network or
    /// from nowhere, so they are rejected.
    public static func isPublic(_ address: Address) -> Bool {
        switch address {
        case .v4(let a, let b, let c, _):
            // 0.0.0.0/8 "this network".
            if a == 0 { return false }
            // 10.0.0.0/8 private.
            if a == 10 { return false }
            // 100.64.0.0/10 carrier-grade NAT.
            if a == 100 && (64...127).contains(b) { return false }
            // 127.0.0.0/8 loopback.
            if a == 127 { return false }
            // 169.254.0.0/16 link-local.
            if a == 169 && b == 254 { return false }
            // 172.16.0.0/12 private.
            if a == 172 && (16...31).contains(b) { return false }
            // 192.0.0.0/24 IETF protocol assignments.
            if a == 192 && b == 0 && c == 0 { return false }
            // 192.0.2.0/24 TEST-NET-1.
            if a == 192 && b == 0 && c == 2 { return false }
            // 192.88.99.0/24 former 6to4 relay anycast, deprecated.
            if a == 192 && b == 88 && c == 99 { return false }
            // 192.168.0.0/16 private.
            if a == 192 && b == 168 { return false }
            // 198.18.0.0/15 benchmarking.
            if a == 198 && (18...19).contains(b) { return false }
            // 198.51.100.0/24 TEST-NET-2.
            if a == 198 && b == 51 && c == 100 { return false }
            // 203.0.113.0/24 TEST-NET-3.
            if a == 203 && b == 0 && c == 113 { return false }
            // 224.0.0.0/4 multicast.
            if (224...239).contains(a) { return false }
            // 240.0.0.0/4 reserved, includes the broadcast address.
            if a >= 240 { return false }
            return true
        case .v6(let bytes):
            // A truncated or extended value is not an address at all.
            guard bytes.count == 16 else { return false }
            // IPv4-mapped addresses carry an IPv4 answer; check that.
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isPublic(.v4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            // NAT64 well-known prefix, which an IPv6-only network
            // synthesizes for IPv4 hosts; the embedded IPv4 decides.
            if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4..<12].allSatisfy({ $0 == 0 }) {
                return isPublic(.v4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            // Every other public address lives in 2000::/3, the global
            // unicast block. Requiring it rules out ::, ::1, unique local,
            // link-local, site-local, multicast and every reserved block
            // without having to list them.
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            // 2001::/23 IETF protocol assignments: Teredo, benchmarking
            // and other tunnel or test ranges, never a web server.
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] & 0xfe == 0x00 { return false }
            // 2001:db8::/32 documentation.
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
            // 2002::/16 6to4; the embedded IPv4 decides.
            if bytes[0] == 0x20 && bytes[1] == 0x02 {
                return isPublic(.v4(bytes[2], bytes[3], bytes[4], bytes[5]))
            }
            // 3fff::/20 documentation.
            if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0x00 { return false }
            return true
        }
    }

    /// The media type of a Content-Type value: the part before the first
    /// semicolon, trimmed and lowercased. nil when there is none.
    private static func mediaType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let type = contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return type.isEmpty ? nil : type.lowercased()
    }

    /// Only document media types. A preview is never built from a
    /// download or an API response.
    public static func acceptsHTML(contentType: String?) -> Bool {
        guard let type = mediaType(contentType) else { return false }
        return type == "text/html" || type == "application/xhtml+xml"
    }

    /// Only raster image types. SVG is excluded: it is a document format
    /// that can carry script and external references.
    public static func acceptsImage(contentType: String?) -> Bool {
        guard let type = mediaType(contentType) else { return false }
        return [
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/webp",
            "image/avif",
            "image/heic",
        ].contains(type)
    }
}

/// Builds a preview from the first bytes of an HTML page.
///
/// Parsing is purely local: nothing is executed and nothing is fetched.
public enum LinkPreviewParser: Sendable {
    /// Builds a preview from the first bytes of an HTML page.
    /// `requested` is the address the user entered; `final` is the address
    /// that answered after redirects (the base for relative references).
    public static func preview(html: Data, charset: String?, requested: URL, final resolved: URL) -> LinkPreview? {
        // A page larger than the cap is cut before decoding, so a hostile
        // page cannot exhaust memory.
        let data = html.count > LinkPreviewPolicy.maximumHTMLBytes
            ? Data(html.prefix(LinkPreviewPolicy.maximumHTMLBytes))
            : html
        let text = decode(data, charset: charset)
        guard let document = try? SwiftSoup.parse(text) else { return nil }

        // The first candidate that survives cleaning wins; a page cannot
        // hide an empty card behind a zero-width title.
        let title = firstCleaned(in: document, keys: ["og:title", "twitter:title"], fallback: try? document.title(), limit: LinkPreviewPolicy.maximumTitleLength)
        guard let title else { return nil }

        let summary = firstCleaned(in: document, keys: ["og:description", "twitter:description", "description"], fallback: nil, limit: LinkPreviewPolicy.maximumSummaryLength) ?? ""

        let siteName = firstCleaned(in: document, keys: ["og:site_name"], fallback: nil, limit: LinkPreviewPolicy.maximumSiteNameLength)
            ?? siteNameFromHost(resolved.host)

        let imageURL = previewImage(in: document, base: resolved)

        return LinkPreview(url: requested, title: title, summary: summary, siteName: siteName, imageURL: imageURL)
    }

    /// First candidate whose cleaned text is non-empty, so an empty or
    /// invisible value does not shadow a usable later candidate.
    private static func firstCleaned(in document: Document, keys: [String], fallback: String?, limit: Int) -> String? {
        for key in keys {
            guard let content = metaContent(in: document, for: key) else { continue }
            let cleaned = clean(content, limit: limit)
            if !cleaned.isEmpty { return cleaned }
        }
        guard let fallback else { return nil }
        let cleaned = clean(fallback, limit: limit)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// First non-empty `content` of a meta tag whose `property` or `name`
    /// matches `key`, case-insensitively. Some pages use
    /// `name="og:title"`; both spellings are accepted.
    private static func metaContent(in document: Document, for key: String) -> String? {
        metaContents(in: document, for: key).first
    }

    /// Every non-empty `content` of the meta tags whose `property` or
    /// `name` matches `key`, in document order.
    private static func metaContents(in document: Document, for key: String) -> [String] {
        guard let metas = try? document.select("meta") else { return [] }
        var contents: [String] = []
        for meta in metas {
            let property = (try? meta.attr("property"))?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let name = (try? meta.attr("name"))?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard property == key || name == key else { continue }
            let content = (try? meta.attr("content")) ?? ""
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contents.append(content)
            }
        }
        return contents
    }

    /// The first image reference that resolves against the final
    /// address to an eligible URL. A protocol-relative or path-relative
    /// reference is fine; an http or private-host reference is dropped
    /// and the next candidate is tried.
    private static func previewImage(in document: Document, base: URL) -> URL? {
        for key in ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"] {
            for content in metaContents(in: document, for: key) {
                let reference = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reference.isEmpty, let url = URL(string: reference, relativeTo: base)?.absoluteURL else { continue }
                if LinkPreviewPolicy.isEligible(url) { return url }
            }
        }
        return nil
    }

    /// The site name from the final host, lowercased and without a
    /// leading "www.".
    private static func siteNameFromHost(_ host: String?) -> String {
        guard let host, !host.isEmpty else { return "" }
        var name = host.lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        if name.hasPrefix("www.") {
            name.removeFirst("www.".count)
        }
        return clean(name, limit: LinkPreviewPolicy.maximumSiteNameLength)
    }

    /// Decode the page with the declared charset when Foundation knows
    /// it, then with the page's own meta declaration, then as UTF-8. A
    /// UTF-8 byte order mark outranks both announcements, as in browsers.
    private static func decode(_ data: Data, charset: String?) -> String {
        if data.starts(with: utf8ByteOrderMark) {
            // Lenient: the size cap may have cut the page inside a character.
            return String(decoding: data.dropFirst(utf8ByteOrderMark.count), as: UTF8.self)
        }
        if let charset, let encoding = stringEncoding(forIANA: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let declared = declaredCharset(in: data), let encoding = stringEncoding(forIANA: declared), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // Lenient UTF-8 keeps a broken page previewable without ever
        // executing anything.
        return String(decoding: data, as: UTF8.self)
    }

    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The `String.Encoding` for an IANA charset name, or nil when
    /// Foundation does not know it.
    private static func stringEncoding(forIANA name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    /// The charset a page declares about itself in the first 2048 bytes,
    /// from either `<meta charset=...>` or an `http-equiv` content-type.
    /// Only a meta tag counts: "charset=" in a title or a script is text.
    /// Inside the tag the word must start an attribute or a content-type
    /// parameter; "?charset=" in an address held by another meta tag is
    /// not a declaration.
    private static func declaredCharset(in data: Data) -> String? {
        let prefix = data.prefix(2048)
        let text = String(decoding: prefix, as: UTF8.self).lowercased()
        let pattern = #/<meta\b[^>]*?[\s;"']charset\s*=\s*["']?([a-z0-9._:-]+)/#
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }

    /// Collapse whitespace runs, strip characters a page could use to
    /// reorder or hide text in the card, trim, then cap the length with
    /// an ellipsis.
    private static func clean(_ text: String, limit: Int) -> String {
        let collapsed = collapseWhitespace(text)
        let filtered = String(collapsed.unicodeScalars.filter { !isHidden($0) })
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Each run of whitespace, including newlines and U+00A0, becomes
    /// one space, so a page cannot break the card's layout.
    private static func collapseWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace && !result.isEmpty {
                result.append(" ")
            }
            pendingSpace = false
            result.append(scalar)
        }
        if pendingSpace && !result.isEmpty {
            result.append(" ")
        }
        return String(result)
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{00A0}" || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Control characters, invisible characters and bidirectional
    /// controls are removed so a page cannot reorder or hide text in the
    /// card. The zero-width joiner and non-joiner stay: emoji sequences
    /// and several scripts need them.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1f, 0x7f...0x9f, 0xad: return true
        case 0x061c, 0x200b, 0x200e, 0x200f, 0x202a...0x202e: return true
        case 0x2060...0x206f, 0xfeff: return true
        default: return false
        }
    }
}
