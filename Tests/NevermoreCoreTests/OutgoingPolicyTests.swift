import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Test func workingHoursUseSiteWallClockAndRespectNudgePreference() {
    let hours = RavenQuietHoursConfig(workingHoursStart: "9:00:00", workingHoursEnd: "17:00:00")
    let clock = ISO8601DateFormatter()
    let during = clock.date(from: "2026-11-07T08:00:00Z")! // 09:00 Zurich
    let after = clock.date(from: "2026-11-07T16:00:00Z")! // exclusive 17:00
    #expect(OutgoingPolicy.decision(now: during, workingHours: hours, timezone: "Europe/Zurich", preference: .autoSilent) == .normal)
    #expect(OutgoingPolicy.decision(now: after, workingHours: hours, timezone: "Europe/Zurich", preference: .autoSilent) == .silent)
    #expect(OutgoingPolicy.decision(now: after, workingHours: hours, timezone: "Europe/Zurich", preference: .nudge) == .ask)
    #expect(OutgoingPolicy.decision(now: after, workingHours: hours, timezone: "Europe/Zurich", preference: .noNudge) == .normal)
    #expect(OutgoingPolicy.decision(now: after, workingHours: nil, timezone: "Europe/Zurich", preference: .autoSilent) == .normal)
    #expect(OutgoingPolicy.decision(now: after, workingHours: hours, timezone: "Invalid", preference: .autoSilent) == .normal)
}

@Test func overnightWorkingHoursAreDistinctFromLocalNotificationSuppression() {
    let hours = RavenQuietHoursConfig(workingHoursStart: "22:00:00", workingHoursEnd: "6:00:00")
    let date = ISO8601DateFormatter().date(from: "2026-11-07T23:30:00Z")!
    #expect(OutgoingPolicy.decision(now: date, workingHours: hours, timezone: "UTC", preference: .autoSilent) == .normal)
    let localQuiet = QuietHours(startMinute: 22*60, endMinute: 6*60, timezone: "UTC", enabled: true)
    #expect(!NotificationPolicy.shouldNotify(now: date, quietHours: localQuiet, isForeground: false, enabled: true, muted: false))
}

@Test func silentSendIsDurableImmutableAndLegacyCompatible() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSilent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AccountStore(directory: directory)
    try await store.saveDraft(Draft(channelID: "c", html: "quiet text"))
    let accepted = try await store.acceptDraft(channelID: "c", sendSilently: true)
    #expect(try await store.operations().first?.sendSilently == true)
    var changed = accepted; changed.sendSilently = false
    await #expect(throws: StoreError.immutableFieldChanged("payload")) { try await store.updateOperation(changed) }
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(accepted)) as! [String: Any]
    json.removeValue(forKey: "sendSilently")
    let old = try JSONDecoder().decode(SendOperation.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.sendSilently == nil)
    #expect(old.id == accepted.id && old.html == "quiet text")
}
