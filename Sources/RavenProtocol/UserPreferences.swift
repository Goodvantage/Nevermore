import Foundation

/// Typed view of the Raven User preference fields Nevermore reads and writes.
///
/// Schema verified against Raven `develop` revision
/// `9b01029a92f790e999aab8973e428601261615d1`:
///
/// - `raven/raven/doctype/raven_user/raven_user.json` — `availability_status`
///   (Select: `""`, `Available`, `Away`, `Do not disturb`, `Invisible`),
///   `custom_status` (Data), `hide_read_receipts` (Check, default 0), and
///   `quiet_hours_nudge` (Select: `No Nudge`, `Nudge`, `Auto Silent`,
///   default `Nudge`). The Raven User document is named after the Frappe user
///   ID (`RavenUser.autoname` in `raven_user.py`).
/// - `raven/api/raven_users.py` — `get_current_raven_user` returns the current
///   user's Raven User document; `update_raven_user` exists but is deprecated
///   in v3. The current web client writes these fields with
///   `frappe.client.set_value`; Nevermore uses the generic
///   `PUT /api/resource/Raven User/<name>` route, which Frappe 15/16 handles
///   with `doc.check_permission("write")` (verified in the pinned Frappe
///   revisions' `frappe/api/v1.py`).
///
/// Raven has **no per-user quiet-hours window**. The only quiet-hours field on
/// Raven User is `quiet_hours_nudge`, which controls composer behavior outside
/// the organization's working hours. The working-hours window itself is a
/// Raven Settings singleton, exposed read-only through `raven.api.native.boot`
/// as `quiet_hours` (see ``RavenQuietHoursConfig``). Per-account quiet-hours
/// windows are therefore a local Nevermore preference, not a server setting.
public struct RavenUserPreferences: Codable, Sendable, Equatable {
    /// The server document verbatim, including unknown fields.
    public var raw: JSONValue
    /// Raven User document name (the Frappe user ID).
    public var name: String
    /// Linked Frappe User ID.
    public var user: String
    public var fullName: String
    public var availabilityStatus: String
    public var customStatus: String
    public var hideReadReceipts: Bool
    public var quietHoursNudge: RavenQuietHoursNudge
    /// The server's raw `quiet_hours_nudge` string, retained so an unknown
    /// value can be displayed without being silently rewritten.
    public var quietHoursNudgeRaw: String

    public init(raw: JSONValue) {
        self.raw = raw
        self.name = raw["name"].string ?? ""
        self.user = raw["user"].string ?? ""
        self.fullName = raw["full_name"].string ?? ""
        self.availabilityStatus = raw["availability_status"].string ?? ""
        self.customStatus = raw["custom_status"].string ?? ""
        self.hideReadReceipts = raw["hide_read_receipts"].bool
        let nudgeRaw = raw["quiet_hours_nudge"].string ?? ""
        self.quietHoursNudgeRaw = nudgeRaw
        // The doctype default is "Nudge"; an empty/unknown value falls back to it.
        self.quietHoursNudge = RavenQuietHoursNudge(rawValue: nudgeRaw) ?? .nudge
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    /// Unknown and missing server policies must not silently become a known policy.
    public var supportedQuietHoursNudge: RavenQuietHoursNudge? {
        guard raw.object.keys.contains("quiet_hours_nudge") else { return nil }
        return quietHoursNudgeRaw.isEmpty ? .nudge : RavenQuietHoursNudge(rawValue: quietHoursNudgeRaw)
    }

    /// Select options from the verified Raven User schema, in schema order.
    public static let availabilityOptions = ["", "Available", "Away", "Do not disturb", "Invisible"]

    /// The only Raven User preference field names Nevermore may write.
    /// Any other key in a requested mutation is dropped before transport.
    public static let verifiedFields: Set<String> = [
        "availability_status",
        "custom_status",
        "hide_read_receipts",
        "quiet_hours_nudge",
    ]

    /// Drops every unverified field from a proposed mutation dictionary.
    /// Callers may build a dictionary with extra keys; only the verified Raven
    /// User field names survive.
    public static func sanitizedMutation(_ values: [String: JSONValue]) -> [String: JSONValue] {
        values.filter { verifiedFields.contains($0.key) }
    }

    /// A mutation dictionary containing only verified fields whose values
    /// differ from this document. Passing the result through
    /// ``sanitizedMutation(_:)`` is still recommended as a defense in depth.
    public func mutation(
        availabilityStatus: String? = nil,
        customStatus: String? = nil,
        hideReadReceipts: Bool? = nil,
        quietHoursNudge: RavenQuietHoursNudge? = nil
    ) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        if let availabilityStatus, raw.object.keys.contains("availability_status"), Self.availabilityOptions.contains(availabilityStatus), availabilityStatus != self.availabilityStatus {
            values["availability_status"] = .string(availabilityStatus)
        }
        if let customStatus, raw.object.keys.contains("custom_status"), customStatus != self.customStatus {
            values["custom_status"] = .string(customStatus)
        }
        if let hideReadReceipts, raw.object.keys.contains("hide_read_receipts"), hideReadReceipts != self.hideReadReceipts {
            values["hide_read_receipts"] = .bool(hideReadReceipts)
        }
        if let quietHoursNudge, raw.object.keys.contains("quiet_hours_nudge"), quietHoursNudge != self.quietHoursNudge {
            values["quiet_hours_nudge"] = .string(quietHoursNudge.rawValue)
        }
        return Self.sanitizedMutation(values)
    }
}

/// The after-hours composer preference stored on Raven User.
public enum RavenQuietHoursNudge: String, Codable, Sendable, CaseIterable {
    case noNudge = "No Nudge"
    case nudge = "Nudge"
    case autoSilent = "Auto Silent"
}

/// The organization-wide working-hours window exposed read-only through
/// `raven.api.native.boot` as `quiet_hours`.
///
/// Verified against `raven/boot.py` at the pinned revision: when
/// `Raven Settings.enable_quiet_hours` is set and both time fields are
/// present, boot contains `quiet_hours` with `working_hours_start` and
/// `working_hours_end` strings (`"HH:MM:SS"` or `"H:MM:SS"`). There is no
/// per-account equivalent on Raven User.
public struct RavenQuietHoursConfig: Codable, Sendable, Equatable {
    public var workingHoursStart: String
    public var workingHoursEnd: String

    public init(raw: JSONValue) {
        self.workingHoursStart = raw["working_hours_start"].string ?? ""
        self.workingHoursEnd = raw["working_hours_end"].string ?? ""
    }

    public init(workingHoursStart: String, workingHoursEnd: String) {
        self.workingHoursStart = workingHoursStart
        self.workingHoursEnd = workingHoursEnd
    }

    public var startMinute: Int? { Self.minute(workingHoursStart) }
    public var endMinute: Int? { Self.minute(workingHoursEnd) }

    /// Parses the `"HH:MM:SS"` / `"H:MM:SS"` form Frappe uses for Time fields.
    static func minute(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.count == 2 || (Double(parts[2]).map { $0.isFinite && $0 >= 0 && $0 < 60 } ?? false),
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              (0..<24).contains(hours),
              (0..<60).contains(minutes) else { return nil }
        return hours * 60 + minutes
    }
}
