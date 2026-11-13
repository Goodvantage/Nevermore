import Foundation
import RavenProtocol

/// A snapshot may authorize removal only inside the fully covered ordered span.
/// Absence in a random page, a search result or a stale HTTP generation is not deletion.
public enum MessageReconciliation {
    public static func ordered(_ a: RavenMessage, _ b: RavenMessage) -> Bool {
        (a.creation, a.id) < (b.creation, b.id)
    }
    public static func observedDeletions(existing: [RavenMessage], snapshot: [RavenMessage], channelID: String, authoritative: Bool) -> [String] {
        guard authoritative, !snapshot.isEmpty,
              snapshot.allSatisfy({ $0.channelID == channelID && !$0.id.isEmpty && !$0.creation.isEmpty }),
              Set(snapshot.map(\.id)).count == snapshot.count,
              let lower = snapshot.min(by: ordered), let upper = snapshot.max(by: ordered) else { return [] }
        let ids = Set(snapshot.map(\.id))
        return existing.filter { $0.channelID == channelID && !ordered($0, lower) && !ordered(upper, $0) && !ids.contains($0.id) }.map(\.id)
    }
}
