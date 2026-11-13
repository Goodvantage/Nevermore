import Foundation
import Testing
@testable import NevermoreCore

@Suite struct StatusAnnouncementPolicyTests {
    @Test func backgroundAndUnfocusedEventsAreNotReplayedOnFocus() {
        var policy = StatusAnnouncementPolicy()
        let context = UUID()
        #expect(policy.update(context: context, attention: [.accountAttention], isForegroundKeyWindow: false, isComposing: false).isEmpty)
        #expect(policy.update(context: context, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false).isEmpty)
        #expect(policy.update(context: context, attention: [], isForegroundKeyWindow: true, isComposing: false).isEmpty)
        #expect(policy.update(context: context, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false) == [.accountAttention])
    }

    @Test func markedTextSuppressesRatherThanDefersSpeech() {
        var policy = StatusAnnouncementPolicy()
        let context = UUID()
        #expect(policy.update(context: context, attention: [.conversationAccessLost], isForegroundKeyWindow: true, isComposing: true).isEmpty)
        #expect(policy.update(context: context, attention: [.conversationAccessLost], isForegroundKeyWindow: true, isComposing: false).isEmpty)
        #expect(policy.update(context: context, attention: [.accountAttention, .conversationAccessLost], isForegroundKeyWindow: true, isComposing: false) == [.accountAttention])
    }

    @Test func repeatedFailuresAndAccessLossAreDeduplicatedUntilRecovery() {
        var policy = StatusAnnouncementPolicy()
        let context = UUID()
        let both: Set<StatusAnnouncement> = [.accountAttention, .conversationAccessLost]
        #expect(policy.update(context: context, attention: both, isForegroundKeyWindow: true, isComposing: false) == StatusAnnouncement.allCases)
        for _ in 0..<100 {
            #expect(policy.update(context: context, attention: both, isForegroundKeyWindow: true, isComposing: false).isEmpty)
        }
        #expect(policy.update(context: context, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false).isEmpty)
        #expect(policy.update(context: context, attention: both, isForegroundKeyWindow: true, isComposing: false) == [.conversationAccessLost])
    }

    @Test func contextChangesAndInvalidationDiscardPreviousMetadata() {
        var policy = StatusAnnouncementPolicy()
        let first = UUID(), second = UUID()
        #expect(policy.update(context: first, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false) == [.accountAttention])
        #expect(policy.update(context: second, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false) == [.accountAttention])
        #expect(policy.update(context: nil, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false).isEmpty)
        #expect(policy.update(context: second, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false) == [.accountAttention])
        policy.reset()
        #expect(policy.update(context: second, attention: [.accountAttention], isForegroundKeyWindow: true, isComposing: false) == [.accountAttention])
    }

    @Test func manyContextsDoNotAccumulatePendingAnnouncements() {
        var policy = StatusAnnouncementPolicy()
        for _ in 0..<10_000 {
            #expect(policy.update(context: UUID(), attention: [.accountAttention, .conversationAccessLost], isForegroundKeyWindow: false, isComposing: false).isEmpty)
        }
        let final = UUID()
        #expect(policy.update(context: final, attention: [], isForegroundKeyWindow: true, isComposing: false).isEmpty)
        #expect(policy.update(context: final, attention: [.conversationAccessLost], isForegroundKeyWindow: true, isComposing: false) == [.conversationAccessLost])
    }

    @Test func spokenMessagesContainOnlyFixedActionableCopy() {
        #expect(StatusAnnouncement.accountAttention.message == "This account needs attention. Review its status or reconnect from account settings.")
        #expect(StatusAnnouncement.conversationAccessLost.message == "Conversation access changed. Choose another conversation. Your draft is preserved.")
        let context = UUID()
        var policy = StatusAnnouncementPolicy()
        let messages = policy.update(context: context, attention: Set(StatusAnnouncement.allCases), isForegroundKeyWindow: true, isComposing: false).map(\.message)
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { !$0.contains(context.uuidString) && !$0.contains("https://") && !$0.contains("@") })
    }
}
