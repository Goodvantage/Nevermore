import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    public var object: [String: JSONValue] { if case .object(let a) = self { return a }; return [:] }
    /// A count or byte size from a Raven row. Integer strings through
    /// Int64.max retain their precision without a round trip through Double.
    public var nonnegativeCount: Int64? {
        switch self {
        case .number(let number) where number >= 0: return Int64(exactly: number)
        case .string(let text):
            if let count = Int64(text) { return count >= 0 ? count : nil }
            return Self.integralDecimal(text)
        default: return nil
        }
    }
    /// Some adapters return decimal or scientific notation. Work in decimal
    /// digits so underflow and rounded fractions cannot become valid counts.
    private static func integralDecimal(_ text: String) -> Int64? {
        guard let match = text.wholeMatch(of: #/([+-]?)([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?/#) else { return nil }
        let (_, sign, whole, fraction, power) = match.output
        let digits = whole + (fraction ?? "")
        guard !digits.isEmpty else { return nil }
        let significant = digits.drop(while: { $0 == "0" })
        guard !significant.isEmpty else { return 0 }
        guard sign != "-", let exponent = Int(power ?? "0") else { return nil }
        let (scale, overflow) = exponent.subtractingReportingOverflow(fraction?.count ?? 0)
        guard !overflow else { return nil }
        if scale < 0 {
            guard scale >= -significant.count, significant.suffix(-scale).allSatisfy({ $0 == "0" }) else { return nil }
            return Int64(significant.dropLast(-scale))
        }
        guard significant.count <= 19, scale <= 19 - significant.count else { return nil }
        return Int64(String(significant) + String(repeating: "0", count: scale))
    }

    public var bool: Bool { switch self { case .bool(let b): return b; case .number(let n): return n != 0; case .string(let s): return s == "1" || s == "true"; default: return false } }
    public var nested: JSONValue { if let s = string, let data = s.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data) { return value }; return self }
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var origin: URL
    public var user: String
    public var siteName: String
    public var clientID: String
    public var displayName: String
    public var timezone: String
    public init(id: UUID = UUID(), origin: URL, user: String, siteName: String, clientID: String, displayName: String = "", timezone: String = "UTC") {
        self.id = id; self.origin = origin; self.user = user; self.siteName = siteName; self.clientID = clientID; self.displayName = displayName; self.timezone = timezone
    }
}
public struct RavenMessage: Codable, Sendable, Equatable, Identifiable {
    public var raw: JSONValue
    public var id: String { raw["name"].string ?? "" }
    public var channelID: String { raw["channel_id"].string ?? "" }
    public var owner: String { raw["owner"].string ?? "" }
    public var html: String { raw["text"].string ?? "" }
    public var creation: String { raw["creation"].string ?? "" }
    public var messageType: String { raw["message_type"].string ?? "Unknown" }
    public var batchID: String? { raw["message_batch_id"].string }
    /// The user Raven shows as the author. A bot message is owned by the
    /// Frappe user the bot posts as, so the bot is the author, not the owner.
    /// Permission checks keep using `owner`.
    public var authorID: String {
        guard raw["is_bot_message"].bool, let bot = raw["bot"].string, !bot.isEmpty else { return owner }
        return bot
    }
    public init(raw: JSONValue) { self.raw = raw }
}
public struct RavenChannel: Codable, Sendable, Equatable, Identifiable {
    public var raw: JSONValue
    public var id: String { raw["name"].string ?? "" }
    public var title: String { raw["channel_name_for_current_user"].string ?? raw["channel_name"].string ?? id }
    public var workspace: String { raw["workspace"].string ?? raw["raven_workspace"].string ?? "" }
    public var isDM: Bool { raw["is_direct_message"].bool }
    public init(raw: JSONValue) { self.raw = raw }
}
