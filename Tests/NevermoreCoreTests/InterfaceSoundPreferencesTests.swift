import Testing
@testable import NevermoreCore

@Suite struct InterfaceSoundPreferencesTests {
    private func assertSendable<T: Sendable>(_ value: T) {}

    // MARK: - Resolution

    @Test func defaultsToDisabledAtDefaultVolume() {
        let prefs = InterfaceSoundPreferences()
        #expect(prefs.isEnabled == false)
        #expect(prefs.volume == InterfaceSoundPreferences.defaultVolume)
        #expect(prefs.volume == 0.35)
        #expect(InterfaceSoundPreferences.enabledKey == "interfaceSounds")
        #expect(InterfaceSoundPreferences.volumeKey == "interfaceSoundVolume")
        #expect(InterfaceSoundPreferences(enabled: nil, volume: nil) == prefs)
    }

    @Test func enabledInputIsPreserved() {
        #expect(InterfaceSoundPreferences(enabled: true).isEnabled)
        #expect(InterfaceSoundPreferences(enabled: false).isEnabled == false)
        #expect(InterfaceSoundPreferences(enabled: nil).isEnabled == false)
        let stored = InterfaceSoundPreferences(enabled: true, volume: 0.8)
        #expect(stored == InterfaceSoundPreferences(enabled: true, volume: 0.8))
        #expect(stored != InterfaceSoundPreferences(enabled: false, volume: 0.8))
    }

    @Test func finiteVolumeIsClampedToUnitRange() {
        #expect(InterfaceSoundPreferences(volume: 0.8).volume == 0.8)
        #expect(InterfaceSoundPreferences(volume: 1).volume == 1)
        #expect(InterfaceSoundPreferences(volume: 2).volume == 1)
        #expect(InterfaceSoundPreferences(volume: 0).volume == 0)
        #expect(InterfaceSoundPreferences(volume: -0.25).volume == 0)
        #expect(InterfaceSoundPreferences(volume: -3).volume == 0)
    }

    @Test func missingOrNonfiniteVolumeFallsBackToDefault() {
        let expected = InterfaceSoundPreferences.defaultVolume
        #expect(InterfaceSoundPreferences(volume: nil).volume == expected)
        #expect(InterfaceSoundPreferences(volume: .nan).volume == expected)
        #expect(InterfaceSoundPreferences(volume: .infinity).volume == expected)
        #expect(InterfaceSoundPreferences(volume: -.infinity).volume == expected)
        // Non-finite volume is replaced, but a valid enabled flag survives.
        let prefs = InterfaceSoundPreferences(enabled: true, volume: .nan)
        #expect(prefs.isEnabled)
        #expect(prefs.volume == expected)
    }

    @Test func valuesAreSendable() {
        assertSendable(InterfaceSoundPreferences(enabled: true, volume: 0.5))
        assertSendable(InterfaceSoundGate())
        assertSendable(InterfaceSoundGate.Context.preview)
    }

    // MARK: - Context suppression

    @Test func automationAndBackgroundAreAlwaysRejected() {
        var gate = InterfaceSoundGate()
        let prefs = InterfaceSoundPreferences(enabled: true, volume: 0.5)
        #expect(gate.accept(preferences: prefs, context: .automation, at: 0) == false)
        #expect(gate.accept(preferences: prefs, context: .background, at: 1) == false)
        #expect(gate.accept(preferences: prefs, context: .automation, at: 2) == false)
        #expect(gate.accept(preferences: prefs, context: .background, at: 3) == false)
    }

    @Test func interactionRequiresEnabledPreferences() {
        var gate = InterfaceSoundGate()
        #expect(gate.accept(preferences: InterfaceSoundPreferences(enabled: false, volume: 0.5), context: .interaction, at: 0) == false)
        #expect(gate.accept(preferences: InterfaceSoundPreferences(enabled: true, volume: 0.5), context: .interaction, at: 1) == true)
    }

    @Test func previewIsExplicitOptInAndPlaysWhileDisabled() {
        var gate = InterfaceSoundGate()
        let disabled = InterfaceSoundPreferences(enabled: false, volume: 0.5)
        #expect(gate.accept(preferences: disabled, context: .preview, at: 0) == true)
        // The accepted preview starts the cooldown even though sounds are off.
        #expect(gate.accept(preferences: disabled, context: .preview, at: 0.05) == false)
    }

    @Test func zeroVolumeIsRejectedInEveryContext() {
        var gate = InterfaceSoundGate()
        let muted = InterfaceSoundPreferences(enabled: true, volume: 0)
        #expect(gate.accept(preferences: muted, context: .interaction, at: 0) == false)
        #expect(gate.accept(preferences: muted, context: .preview, at: 0) == false)
        #expect(gate.accept(preferences: muted, context: .automation, at: 0) == false)
        #expect(gate.accept(preferences: muted, context: .background, at: 0) == false)
        // Disabled preferences with zero volume are still rejected for preview.
        #expect(gate.accept(preferences: InterfaceSoundPreferences(enabled: false, volume: 0), context: .preview, at: 0) == false)
        // The rejections did not consume the cooldown: a tiny positive
        // volume plays immediately.
        #expect(gate.accept(preferences: InterfaceSoundPreferences(enabled: true, volume: 0.001), context: .interaction, at: 0) == true)
    }

    // MARK: - Cooldown

    @Test func burstCooldownSuppressesRapidRepeatsAndAcceptsAtBoundary() {
        var gate = InterfaceSoundGate()
        let prefs = InterfaceSoundPreferences(enabled: true, volume: 0.5)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0) == true)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0.05) == false)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0.119) == false)
        // Exactly 0.12 seconds later is the boundary and plays.
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0.12) == true)
        // The same instant is not a new interval.
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0.12) == false)
    }

    @Test func cooldownIsSharedAcrossContexts() {
        var gate = InterfaceSoundGate()
        let prefs = InterfaceSoundPreferences(enabled: true, volume: 0.5)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0) == true)
        #expect(gate.accept(preferences: prefs, context: .preview, at: 0.06) == false)
        #expect(gate.accept(preferences: prefs, context: .preview, at: 0.12) == true)
    }

    @Test func invalidTimesAreRejected() {
        var gate = InterfaceSoundGate()
        let prefs = InterfaceSoundPreferences(enabled: true, volume: 0.5)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: .nan) == false)
        #expect(gate.accept(preferences: prefs, context: .preview, at: .infinity) == false)
        #expect(gate.accept(preferences: prefs, context: .preview, at: -.infinity) == false)
        #expect(gate.accept(preferences: prefs, context: .preview, at: -1) == false)
        // None of the rejected calls consumed the interval: a valid call at
        // the origin still plays.
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 0) == true)
    }

    @Test func rejectedCallsDoNotConsumeTheCooldownInterval() {
        var gate = InterfaceSoundGate()
        let enabled = InterfaceSoundPreferences(enabled: true, volume: 0.5)
        #expect(gate.accept(preferences: enabled, context: .interaction, at: 0) == true)
        // Rejected at 0.02: wrong context and zero volume.
        #expect(gate.accept(preferences: enabled, context: .automation, at: 0.02) == false)
        #expect(gate.accept(preferences: InterfaceSoundPreferences(enabled: true, volume: 0), context: .interaction, at: 0.02) == false)
        // If either rejection had moved the cooldown origin to 0.02, this
        // call would be 0.10s later and suppressed; measured from the real
        // accept at 0 it sits exactly on the boundary and plays.
        #expect(gate.accept(preferences: enabled, context: .preview, at: 0.12) == true)
    }

    @Test func backwardClockIsRejectedAndDoesNotConsumeTheInterval() {
        var gate = InterfaceSoundGate()
        let prefs = InterfaceSoundPreferences(enabled: true, volume: 0.5)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 5) == true)
        #expect(gate.accept(preferences: prefs, context: .preview, at: 4.9) == false)
        // 5.05 would clear a cooldown restarted at 4.9 (0.15s) but is only
        // 0.05s after the real accept, so it must be suppressed.
        #expect(gate.accept(preferences: prefs, context: .preview, at: 5.05) == false)
        #expect(gate.accept(preferences: prefs, context: .interaction, at: 5.5) == true)
    }
}
