import Foundation
import Testing
@testable import RavenProtocol

@Test func newerUserPreferencesPreserveUnknownFieldsWithoutInventingOlderCapabilities() throws {
    let raw = JSONValue.object(["name": .string("u"), "availability_status": .string("Future state"), "quiet_hours_nudge": .string("Future policy"), "future_setting": .object(["secret": .bool(true)])])
    let preferences = RavenUserPreferences(raw: raw)
    let round = try JSONDecoder().decode(RavenUserPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(round.raw == raw)
    #expect(preferences.mutation(customStatus: "new", hideReadReceipts: true).isEmpty)
    #expect(preferences.mutation(availabilityStatus: "Unverified").isEmpty)
    #expect(preferences.quietHoursNudgeRaw == "Future policy")
    #expect(preferences.supportedQuietHoursNudge == nil)
    #expect(RavenUserPreferences(raw: .object([:])).supportedQuietHoursNudge == nil)
    #expect(RavenUserPreferences.sanitizedMutation(["future_setting": .bool(false), "custom_status": .string("ok")]) == ["custom_status": .string("ok")])
}

@Test func organizationTimeParsingRejectsMalformedAndOutOfRangeValues() {
    #expect(RavenQuietHoursConfig(workingHoursStart: "9:30:00", workingHoursEnd: "17:00").startMinute == 570)
    for bad in ["", "24:00:00", "09:60:00", "09::00", "09:00:nope", "09:00:60", "09:00:00:00"] {
        #expect(RavenQuietHoursConfig(workingHoursStart: bad, workingHoursEnd: "17:00:00").startMinute == nil)
    }
}
