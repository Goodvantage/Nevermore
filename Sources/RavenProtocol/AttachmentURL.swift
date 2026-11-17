import Foundation
import os

public enum RavenAttachmentURL {
    private static let log = Logger(subsystem: "ch.goodvantage.Nevermore", category: "Attachments")

    /// Reject missing/degenerate paths before resolving them against the site,
    /// so malformed attachment metadata cannot fetch the site root.
    public static func resolve(_ value: String, origin: URL) throws -> URL {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RavenError.invalidResponse }
        // Dot-segment checks run on the raw value: URL parsing resolves literal
        // `.`/`..` away before the result can be inspected, and a credentialed
        // fetch must not travel outside the path the metadata named. Tolerant
        // decoding to a fixpoint surfaces encoded and re-encoded traversal alike.
        let rawPath = String(value.prefix { $0 != "?" && $0 != "#" })
        guard !hasDotSegment(rawPath) else {
            Self.log.notice("Rejected attachment URL containing dot segments")
            throw RavenError.invalidResponse
        }
        guard let url = URL(string: value, relativeTo: origin)?.absoluteURL else { throw RavenError.invalidResponse }
        guard SiteOrigin.sameOrigin(url, origin) else { throw RavenError.crossOrigin }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path else { throw RavenError.invalidResponse }
        guard !hasDotSegment(path) else {
            Self.log.notice("Rejected attachment URL containing dot segments")
            throw RavenError.invalidResponse
        }
        let standardized = url.standardized.path
        guard !standardized.isEmpty, standardized != "/", url.fragment == nil else { throw RavenError.invalidResponse }
        return url
    }

    /// True when a `/`-separated path — literal or repeatedly percent-decoded —
    /// contains a `.` or `..` segment. Backslash counts as a separator because
    /// some servers and proxies normalize it to `/`.
    private static func hasDotSegment(_ path: String) -> Bool {
        var current = path
        for _ in 0..<16 {
            if hasDotSegmentOnce(current) { return true }
            let next = decodeTraversalEscapes(current)
            guard next != current else { return false }
            current = next
        }
        // Budget exhausted with input still changing — pathological nesting
        // no legitimate attachment path produces. Fail closed.
        return true
    }

    /// One pass over `/` and `\` separated segments. A segment counts when its
    /// pre-`;` base is a dot segment — some stacks strip `;` matrix parameters
    /// before resolving dots.
    private static func hasDotSegmentOnce(_ path: String) -> Bool {
        path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).contains {
            isDotSegment(String($0.prefix(while: { $0 != ";" })))
        }
    }

    /// True when a segment is a nonempty run of dots — as written, under
    /// compatibility decomposition (fullwidth and leader dots), or after
    /// removing whitespace, control characters and replacement characters
    /// some stacks drop before resolving segments (`..%00`, `..%20`,
    /// overlong-encoded `...`). Three or more dots count too: Windows
    /// resolves `...` as traversal. A segment made only of such characters is
    /// not a legitimate filename and could decode to anything server-side, so
    /// it is rejected too.
    private static func isDotSegment(_ segment: String) -> Bool {
        let cleaned = stripResolvables(segment)
        if !segment.isEmpty, cleaned.isEmpty { return true }
        for candidate in [cleaned, stripResolvables(segment.decomposedStringWithCompatibilityMapping)] {
            if !candidate.isEmpty, candidate.allSatisfy({ $0 == "." }) { return true }
        }
        return false
    }

    /// Characters some stacks delete before resolving path segments:
    /// whitespace, control characters and U+FFFD produced by invalid UTF-8.
    private static func stripResolvables(_ segment: String) -> String {
        String(segment.filter {
            !$0.isWhitespace
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && $0 != "\u{FFFD}"
        })
    }

    /// One tolerant decode pass over every valid percent escape; malformed
    /// escapes are left alone rather than suppressing the rest, unlike
    /// `removingPercentEncoding`. The caller iterates to a fixpoint so deeper
    /// encodings surface.
    private static func decodeTraversalEscapes(_ path: String) -> String {
        let source = Array(path.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
               let hi = hexValue(source[index + 1]), let lo = hexValue(source[index + 2]) {
                out.append(hi << 4 | lo); index += 3; continue
            }
            out.append(source[index]); index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
