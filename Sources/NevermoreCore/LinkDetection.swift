import Foundation

/// Finds web addresses in plain text, for the composer's automatic links.
///
/// All ranges are UTF-16 offsets into the inspected text.
public enum LinkDetection {
    /// One detected address: its exact range and the address it opens.
    public struct Match: Sendable, Equatable {
        public var range: NSRange
        /// The address as typed, trimmed of surrounding punctuation; an
        /// address typed as "www." gains "https://", the way Messages and
        /// Mail link it.
        public var url: String
    }

    private static let maxURLLength = 2048
    /// Wrappers allowed before the scheme, e.g. "(https://a.example)".
    private static let leadingWrapperCharacters = CharacterSet(charactersIn: "([{<\"'\u{201C}\u{2018}")
    /// Trimmed from the end of a candidate address: sentence punctuation
    /// and closing quotes, the fullwidth marks of Chinese and Japanese text
    /// (written without a space after an address), and the zero-width space
    /// and byte order mark that copying can leave behind.
    private static let trailingPunctuationCharacters = CharacterSet(charactersIn: ".,;:!?'\"\u{201D}\u{2019}>\u{3001}\u{3002}\u{FF0C}\u{FF01}\u{FF1A}\u{FF1B}\u{FF1F}\u{200B}\u{FEFF}")
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let bracketCharacters: Set<unichar> = [0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D]
    /// Closing brackets paired with their opening bracket, for balanced trimming.
    private static let bracketPairs: [(close: unichar, open: unichar)] = [
        (0x29, 0x28), // ) (
        (0x5D, 0x5B), // ] [
        (0x7D, 0x7B), // } {
    ]

    /// The web address that ends exactly at `location`, for linking it when
    /// the user types the space or line break after it.
    ///
    /// `location` must be the exact end of the token holding the address:
    /// pass the caret position before the space, or the space's own index.
    public static func webAddress(in text: String, endingAt location: Int) -> Match? {
        let value = text as NSString
        guard location > 0, location <= value.length else { return nil }
        guard !isWhitespace(value.character(at: location - 1)) else { return nil }
        if location < value.length, !isWhitespace(value.character(at: location)) { return nil }
        var start = location - 1
        while start > 0, !isWhitespace(value.character(at: start - 1)) { start -= 1 }
        return match(in: value, tokenRange: NSRange(location: start, length: location - start))
    }

    /// Every web address in `text`, in order, for linking pasted text.
    public static func webAddresses(in text: String) -> [Match] {
        let value = text as NSString
        var matches: [Match] = []
        var index = 0
        while index < value.length {
            while index < value.length, isWhitespace(value.character(at: index)) { index += 1 }
            let start = index
            while index < value.length, !isWhitespace(value.character(at: index)) { index += 1 }
            guard start < index else { break }
            if let match = match(in: value, tokenRange: NSRange(location: start, length: index - start)) {
                matches.append(match)
            }
        }
        return matches
    }

    /// `text` trimmed of whitespace, when it is exactly one web address.
    ///
    /// No leading wrappers and no trailing punctuation trimming: the trimmed
    /// text must itself be the address.
    public static func soleWebAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: whitespace)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: whitespace) == nil else { return nil }
        let value = trimmed as NSString
        guard let schemeStart = addressSchemeStart(in: value), schemeStart == 0 else { return nil }
        guard isSupportedAddress(trimmed) else { return nil }
        return trimmed
    }

    /// Extracts the address from one token, or nil when the token holds none.
    private static func match(in text: NSString, tokenRange: NSRange) -> Match? {
        let token = text.substring(with: tokenRange) as NSString
        // The earlier start wins, so a scheme later in a "www." address (a
        // redirect's target, say) does not hide the address itself.
        guard let schemeOffset = [addressSchemeStart(in: token), wwwStart(in: token)].compactMap({ $0 }).min() else { return nil }
        for offset in 0..<schemeOffset {
            guard let scalar = UnicodeScalar(UInt32(token.character(at: offset))), leadingWrapperCharacters.contains(scalar) else { return nil }
        }
        let addressStart = tokenRange.location + schemeOffset
        var end = tokenRange.location + tokenRange.length
        while end > addressStart {
            guard let scalar = UnicodeScalar(UInt32(text.character(at: end - 1))) else { break }
            if trailingPunctuationCharacters.contains(scalar) {
                end -= 1
                continue
            }
            guard let pair = bracketPairs.first(where: { $0.close == scalar.value }) else { break }
            let counts = bracketCounts(in: text, range: NSRange(location: addressStart, length: end - 1 - addressStart))
            if counts[pair.open, default: 0] > counts[pair.close, default: 0] { break }
            end -= 1
        }
        let range = NSRange(location: addressStart, length: end - addressStart)
        let typed = text.substring(with: range) as String
        let address = addressSchemeStart(in: typed as NSString) == 0 ? typed : "https://" + typed
        guard isSupportedAddress(address), address == typed || isWWWHost(address) else { return nil }
        return Match(range: range, url: address)
    }

    /// The offset of a "www." that starts the address part of a token, for
    /// addresses typed without a scheme. Only leading wrappers may precede it,
    /// so "awww.example" or "x/www.a.example" are not addresses.
    private static func wwwStart(in token: NSString) -> Int? {
        let found = token.range(of: "www.", options: .caseInsensitive)
        guard found.location != NSNotFound else { return nil }
        return found.location
    }

    /// A scheme-less address needs a host of "www." and at least two more
    /// labels, the last one letters only ("www.example.com", not "www.x" or
    /// "www.example.c0m"), so a stray "www." in prose stays text.
    private static func isWWWHost(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host?.lowercased(), host.hasPrefix("www.") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, !labels.contains(where: \.isEmpty), let top = labels.last else { return false }
        return top.count >= 2 && top.allSatisfy { $0.isLetter }
    }

    /// The offset of the first case-insensitive "https://" or "http://".
    private static func addressSchemeStart(in token: NSString) -> Int? {
        let secure = token.range(of: "https://", options: .caseInsensitive)
        let plain = token.range(of: "http://", options: .caseInsensitive)
        switch (secure.location, plain.location) {
        case (NSNotFound, NSNotFound): return nil
        case (let secureStart, NSNotFound): return secureStart
        case (NSNotFound, let plainStart): return plainStart
        case (let secureStart, let plainStart): return min(secureStart, plainStart)
        }
    }

    /// Counts opening and closing brackets, to keep a balanced closing one.
    private static func bracketCounts(in text: NSString, range: NSRange) -> [unichar: Int] {
        var counts: [unichar: Int] = [:]
        for offset in range.location..<(range.location + range.length) {
            let unit = text.character(at: offset)
            if bracketCharacters.contains(unit) {
                counts[unit, default: 0] += 1
            }
        }
        return counts
    }

    /// A supported address parses, has a host, and is at most 2048 units.
    private static func isSupportedAddress(_ address: String) -> Bool {
        guard address.utf16.count <= maxURLLength else { return false }
        guard RichTextCodec.safeURL(address), let url = URL(string: address), let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return whitespace.contains(scalar)
    }
}
