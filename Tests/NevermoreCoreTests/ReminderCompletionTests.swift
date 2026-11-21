import Testing
import RavenProtocol
@testable import NevermoreCore

/// The server contract for completing a fired, unread reminder:
/// `mark_reminder_read(message_id)` marks every reminder of the current user
/// on that message whose `notified` is 1 and `is_read` is 0, and returns no
/// state. See docs/RAVEN-RESEARCH.md and the pinned Raven `reminders.py`.
@Suite(.serialized) struct ReminderCompletionTests {
    private func reminder(_ extra: [String: JSONValue]) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string("Raven Reminder FIXTURE")]
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
    }

    @Test func firedUnreadRequiresNotifiedAndUnread() {
        #expect(ReminderCompletion.isFiredUnread(reminder(["notified": .number(1), "is_read": .number(0)])))
        #expect(!ReminderCompletion.isFiredUnread(reminder(["notified": .number(0), "is_read": .number(0)])),
                "A future reminder has not fired, so completing it would be speculative.")
        #expect(!ReminderCompletion.isFiredUnread(reminder(["notified": .number(1), "is_read": .number(1)])),
                "An already read reminder is not a completion candidate.")
    }

    @Test func missingFlagsCannotIdentifyFiredItems() {
        #expect(!ReminderCompletion.isFiredUnread(reminder(["message": .string("message-fixture")])))
        #expect(!ReminderCompletion.isFiredUnread(reminder(["notified": .number(1)])))
        #expect(!ReminderCompletion.isFiredUnread(reminder(["is_read": .number(0)])))
        #expect(!ReminderCompletion.isFiredUnread(.object([:])))
    }

    @Test func serverFlagFormsAreAccepted() {
        for notified in [JSONValue.bool(true), .number(1), .string("1")] {
            #expect(ReminderCompletion.isFiredUnread(reminder(["notified": notified, "is_read": .bool(false)])))
        }
        for isRead in [JSONValue.bool(false), .number(0), .string("0")] {
            #expect(ReminderCompletion.isFiredUnread(reminder(["notified": .bool(true), "is_read": isRead])))
        }
        #expect(!ReminderCompletion.isFiredUnread(reminder(["notified": .number(2), "is_read": .number(0)])))
    }

    @Test func completionKeysOnTheMessageNotTheReminderName() {
        let row = reminder(["name": .string("Raven Reminder 001"), "message": .string("message-fixture")])
        #expect(ReminderCompletion.messageID(row) == "message-fixture")
        #expect(ReminderCompletion.messageID(reminder(["name": .string("Raven Reminder 001")])) == nil)
        #expect(ReminderCompletion.messageID(reminder(["message": .string(" ")])) == nil)
        #expect(ReminderCompletion.messageID(reminder(["message": .string("bad\nid")])) == nil)
        #expect(ReminderCompletion.messageID(reminder(["message": .string(String(repeating: "x", count: 1025))])) == nil)
    }

    @Test func completionRequiresBothThePredicateAndAMessageID() {
        #expect(ReminderCompletion.canComplete(reminder(["notified": .number(1), "is_read": .number(0), "message": .string("message-fixture")])))
        #expect(!ReminderCompletion.canComplete(reminder(["notified": .number(1), "is_read": .number(0)])))
        #expect(!ReminderCompletion.canComplete(reminder(["notified": .number(0), "is_read": .number(0), "message": .string("message-fixture")])))
    }

    @Test func routeIsThePinnedMethod() {
        #expect(ReminderCompletion.markReadMethod == "raven.api.reminders.mark_reminder_read")
    }
}
