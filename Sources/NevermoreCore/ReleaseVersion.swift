/// A semantic version as defined by the SemVer 2.0.0 specification.
///
/// Build metadata is accepted and preserved in `description`, but it is
/// ignored by equality, hashing and precedence, as SemVer requires. Numeric
/// identifiers are compared by digit count and then lexically, so arbitrarily
/// long fields are ordered by value without integer conversion.
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// The exact string passed to `init?`, including any build metadata.
    public let description: String

    /// Whether a pre-release identifier is present.
    public let isPrerelease: Bool

    private let major: String
    private let minor: String
    private let patch: String
    private let prereleaseIdentifiers: [PrereleaseIdentifier]

    /// Parses `string` as `MAJOR.MINOR.PATCH` with optional pre-release and
    /// build metadata, returning `nil` for any other input.
    ///
    /// The input must be ASCII-only and at most 256 UTF-8 bytes. Numeric
    /// identifiers in the core and pre-release must not carry leading zeroes;
    /// build identifiers may.
    public init?(_ string: String) {
        guard string.utf8.count <= 256 else { return nil }
        guard string.unicodeScalars.allSatisfy({ $0.value <= 0x7F }) else { return nil }

        var remainder: Substring = string[...]

        if let plus = remainder.firstIndex(of: "+") {
            let metadata = remainder[remainder.index(after: plus)...]
            remainder = remainder[..<plus]
            guard Self.isValidBuildMetadata(metadata) else { return nil }
        }

        var identifiers: [PrereleaseIdentifier] = []
        if let hyphen = remainder.firstIndex(of: "-") {
            let prerelease = remainder[remainder.index(after: hyphen)...]
            remainder = remainder[..<hyphen]
            guard Self.isValidPrerelease(prerelease) else { return nil }
            identifiers = prerelease.split(separator: ".", omittingEmptySubsequences: false).map {
                PrereleaseIdentifier(text: String($0), isNumeric: $0.allSatisfy(Self.isASCIIDigit))
            }
        }

        let core = remainder.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy({ Self.isValidNumericIdentifier($0) }) else { return nil }

        description = string
        isPrerelease = !identifiers.isEmpty
        major = String(core[0])
        minor = String(core[1])
        patch = String(core[2])
        prereleaseIdentifiers = identifiers
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        var order = Self.compareNumeric(lhs.major, rhs.major)
        if order == .equal { order = Self.compareNumeric(lhs.minor, rhs.minor) }
        if order == .equal { order = Self.compareNumeric(lhs.patch, rhs.patch) }
        guard order == .equal else { return order == .less }

        // A version without pre-release outranks one with pre-release.
        guard !lhs.prereleaseIdentifiers.isEmpty else { return false }
        guard !rhs.prereleaseIdentifiers.isEmpty else { return true }

        let shared = min(lhs.prereleaseIdentifiers.count, rhs.prereleaseIdentifiers.count)
        for index in 0..<shared {
            let identifierOrder = Self.comparePrereleaseIdentifier(
                lhs.prereleaseIdentifiers[index],
                rhs.prereleaseIdentifiers[index]
            )
            if identifierOrder != .equal { return identifierOrder == .less }
        }
        // Equal prefixes: the shorter identifier set has lower precedence.
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prereleaseIdentifiers == rhs.prereleaseIdentifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prereleaseIdentifiers)
    }

    private enum Order { case less, equal, greater }

    private struct PrereleaseIdentifier: Sendable, Hashable {
        let text: String
        let isNumeric: Bool
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func isValidIdentifier(_ identifier: Substring) -> Bool {
        !identifier.isEmpty && identifier.allSatisfy { character in
            (character >= "0" && character <= "9")
                || (character >= "a" && character <= "z")
                || (character >= "A" && character <= "Z")
                || character == "-"
        }
    }

    private static func isValidNumericIdentifier(_ identifier: Substring) -> Bool {
        guard !identifier.isEmpty, identifier.allSatisfy(Self.isASCIIDigit) else { return false }
        return identifier.count == 1 || identifier.first != "0"
    }

    private static func isValidPrerelease(_ prerelease: Substring) -> Bool {
        for identifier in prerelease.split(separator: ".", omittingEmptySubsequences: false) {
            guard isValidIdentifier(identifier) else { return false }
            if identifier.allSatisfy(Self.isASCIIDigit) {
                guard isValidNumericIdentifier(identifier) else { return false }
            }
        }
        return true
    }

    private static func isValidBuildMetadata(_ metadata: Substring) -> Bool {
        metadata.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy(Self.isValidIdentifier)
    }

    private static func compareNumeric(_ lhs: String, _ rhs: String) -> Order {
        let lhsDigits = String(lhs.drop { $0 == "0" })
        let rhsDigits = String(rhs.drop { $0 == "0" })
        if lhsDigits.count != rhsDigits.count {
            return lhsDigits.count < rhsDigits.count ? .less : .greater
        }
        if lhsDigits == rhsDigits { return .equal }
        return lhsDigits < rhsDigits ? .less : .greater
    }

    private static func comparePrereleaseIdentifier(_ lhs: PrereleaseIdentifier, _ rhs: PrereleaseIdentifier) -> Order {
        if lhs.isNumeric && rhs.isNumeric {
            return compareNumeric(lhs.text, rhs.text)
        }
        // Numeric identifiers always rank below alphanumeric ones.
        if lhs.isNumeric != rhs.isNumeric {
            return lhs.isNumeric ? .less : .greater
        }
        if lhs.text == rhs.text { return .equal }
        return lhs.text < rhs.text ? .less : .greater
    }
}
