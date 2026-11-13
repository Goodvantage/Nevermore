import Testing
@testable import NevermoreCore

@Suite struct GeneralPreferencesTests {
    @Test func menuBarIconDefaultsToTheRaven() {
        #expect(MenuBarIcon(storedValue: nil) == .raven)
        #expect(MenuBarIcon(storedValue: "") == .raven)
        #expect(MenuBarIcon(storedValue: "a later version's icon") == .raven)
    }

    @Test func menuBarIconReadsEveryStoredChoice() {
        for icon in MenuBarIcon.allCases {
            #expect(MenuBarIcon(storedValue: icon.rawValue) == icon)
        }
        #expect(MenuBarIcon.allCases.first == .standard)
    }

    @Test func sendKeyRoundTripsTheStoredBoolean() {
        #expect(ComposerSendKey(returnInsertsNewline: false) == .returnKey)
        #expect(ComposerSendKey(returnInsertsNewline: true) == .commandReturn)
        #expect(!ComposerSendKey.returnKey.returnInsertsNewline)
        #expect(ComposerSendKey.commandReturn.returnInsertsNewline)
    }
}
