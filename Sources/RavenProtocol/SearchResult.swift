import Foundation

/// Frappe SQLiteSearch uses `id = "Raven Message:<opaque name>"` and `author`.
/// Stream/resource messages instead use `name` and `owner`.
public enum RavenSearchResult {
    public static func normalize(_ row: JSONValue) -> JSONValue {
        var fields = row.object
        if fields["name"] == nil, let id = row["id"].string {
            let prefix = "Raven Message:"
            fields["name"] = .string(id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id)
        }
        if fields["owner"] == nil { fields["owner"] = fields["author"] }
        return .object(fields)
    }
}
