import Foundation
import CryptoKit

/// A deterministic portrait seed derived from a username or qualified channel.
///
/// `RavenAvatarDesign` hashes the UTF-8 bytes of the frozen v1 domain separator
/// `"nevermore-raven-v1\u{0000}"` followed by the username in Unicode NFC
/// canonical form (`precomposedStringWithCanonicalMapping`), using SHA-256,
/// and maps the digest bytes onto a stable set of portrait traits. The same
/// username always yields the same design, and canonically equivalent spellings
/// of that username (for example `Jose\u{301}` and `José`) yield the same
/// design as well.
///
/// - Important: The seed is the **username**, not a UI label such as "You".
///   Case and whitespace are significant: they are never folded, trimmed, or
///   otherwise normalized, and no locale rules are applied. Only NFC
///   precomposition is performed, so that canonically equivalent spellings of
///   the same username agree.
///
/// ## Frozen v1 mapping
///
/// The mapping from digest bytes to traits is frozen and must not change:
///
/// - Bytes 0-1: `backgroundHue = (b0*256 + b1) / 65536`
/// - Byte 2: `plumageHue = 0.55 + b2/255*0.20`
/// - Byte 3: `crest = b3 % 5`
/// - Byte 4: `beak = b4 % 4`
/// - Byte 5: `marking = b5 % 5`
/// - Byte 6: `facing = b6 % 2`
/// - Byte 7: `headWidth = 44 + b7 % 11`
/// - Byte 8: `headHeight = 44 + b8 % 11`
/// - Byte 9: `eye = b9 % 3`
/// - Byte 10: `featherCount = 2 + b10 % 4`
/// - Byte 11: `motif = b11 % 4`
/// - All 32 bytes: `fingerprint`, lowercase hexadecimal
///
/// Additional rendering traits use previously unused bytes, preserving every
/// v1 seed and trait: `silhouette = b12 % 4`, `palette = b13 % 6`,
/// `pose = b14 % 2`. These additional mappings are stable as well.
public struct RavenAvatarDesign: Sendable, Equatable {
    /// The SHA-256 digest of the canonical seed payload.
    private let digestBytes: [UInt8]

    /// Creates the design for `name`, the username being seeded.
    ///
    /// - Parameter name: The username, exactly as entered. UI labels such as
    ///   "You" are not valid seeds; callers must pass the username itself.
    public init(name: String) {
        let canonical = name.precomposedStringWithCanonicalMapping
        var payload = Data("nevermore-raven-v1".utf8)
        payload.append(0)
        payload.append(contentsOf: canonical.utf8)
        self.digestBytes = Array(SHA256.hash(data: payload))
    }

    /// Channel names occupy a separate v1 namespace, qualified by workspace.
    /// A UTF-8 byte length makes the pair unambiguous even with separators in
    /// either name. Access level is deliberately not part of the identity.
    public init(channelName: String, workspace: String) {
        let name = channelName.precomposedStringWithCanonicalMapping
        let workspace = workspace.precomposedStringWithCanonicalMapping
        let payload = "nevermore-channel-raven-v1\u{0000}\(workspace.utf8.count):\(workspace)\(name)"
        digestBytes = Array(SHA256.hash(data: Data(payload.utf8)))
    }

    /// Lowercase 64-character hexadecimal encoding of all 32 digest bytes.
    var fingerprint: String {
        let hexDigits = Array("0123456789abcdef")
        var hex = ""
        hex.reserveCapacity(digestBytes.count * 2)
        for byte in digestBytes {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return hex
    }

    /// Background hue in `[0, 1)`, from digest bytes 0 and 1.
    public var backgroundHue: Double {
        (Double(digestBytes[0]) * 256.0 + Double(digestBytes[1])) / 65536.0
    }

    /// Plumage hue in `[0.55, 0.75]`, from digest byte 2.
    public var plumageHue: Double {
        0.55 + Double(digestBytes[2]) / 255.0 * 0.20
    }

    /// Crest shape, from digest byte 3.
    public var crest: Crest { Crest(rawValue: Int(digestBytes[3]) % 5)! }

    /// Beak shape, from digest byte 4.
    public var beak: Beak { Beak(rawValue: Int(digestBytes[4]) % 4)! }

    /// Facial marking, from digest byte 5.
    public var marking: Marking { Marking(rawValue: Int(digestBytes[5]) % 5)! }

    /// Facing direction, from digest byte 6.
    public var facing: Facing { Facing(rawValue: Int(digestBytes[6]) % 2)! }

    /// Head width in `[44, 54]`, from digest byte 7.
    public var headWidth: Double { 44.0 + Double(digestBytes[7] % 11) }

    /// Head height in `[44, 54]`, from digest byte 8.
    public var headHeight: Double { 44.0 + Double(digestBytes[8] % 11) }

    /// Eye shape, from digest byte 9.
    public var eye: Eye { Eye(rawValue: Int(digestBytes[9]) % 3)! }

    /// Feather count in `2...5`, from digest byte 10.
    public var featherCount: Int { 2 + Int(digestBytes[10]) % 4 }

    /// Background motif, from digest byte 11.
    public var motif: Motif { Motif(rawValue: Int(digestBytes[11]) % 4)! }

    public var silhouette: Silhouette { Silhouette(rawValue: Int(digestBytes[12]) % 4)! }
    public var palette: Palette { Palette(rawValue: Int(digestBytes[13]) % 6)! }
    public var pose: Pose { Pose(rawValue: Int(digestBytes[14]) % 2)! }

    public enum Silhouette: Int, CaseIterable, Sendable {
        case round, slender, broad, angular
    }

    public enum Palette: Int, CaseIterable, Sendable {
        case ink, slate, cobalt, teal, plum, rust
    }

    public enum Pose: Int, CaseIterable, Sendable {
        case profile, front
    }

    /// Crest shape; raw values are the frozen v1 mapping of `b3 % 5`.
    public enum Crest: Int, CaseIterable, Sendable {
        case smooth, swept, tousled, spiky, tufted
    }

    /// Beak shape; raw values are the frozen v1 mapping of `b4 % 4`.
    public enum Beak: Int, CaseIterable, Sendable {
        case compact, long, hooked, stout
    }

    /// Facial marking; raw values are the frozen v1 mapping of `b5 % 5`.
    public enum Marking: Int, CaseIterable, Sendable {
        case plain, brow, cheek, bib, mask
    }

    /// Facing direction; raw values are the frozen v1 mapping of `b6 % 2`.
    public enum Facing: Int, CaseIterable, Sendable {
        case left, right
    }

    /// Eye shape; raw values are the frozen v1 mapping of `b9 % 3`.
    public enum Eye: Int, CaseIterable, Sendable {
        case round, almond, curious
    }

    /// Background motif; raw values are the frozen v1 mapping of `b11 % 4`.
    public enum Motif: Int, CaseIterable, Sendable {
        case plain, dots, rays, halo
    }
}
