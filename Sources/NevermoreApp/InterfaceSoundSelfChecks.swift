import AppKit
import NevermoreCore

/// Decode the actual in-memory cues without playing anything. This also
/// runs independently of the long UI fixture.
@MainActor enum InterfaceSoundSelfChecks {
    static func run() -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        var waves = Set<Data>()
        for cue in InterfaceSounds.Cue.allCases {
            let data = InterfaceSounds.audioData(for: cue)
            waves.insert(data)
            let header = data.count > 44 && data.prefix(4) == Data("RIFF".utf8)
                && data[8..<12] == Data("WAVE".utf8)
                && data[36..<40] == Data("data".utf8)
            let sound = NSSound(data: data)
            results.append(("interface cue \(cue) is a short, decodable PCM wave", header && sound.map { $0.duration > 0 && $0.duration < 0.25 } == true))
            results.append(("interface cue \(cue) is deterministic", data == InterfaceSounds.audioData(for: cue)))
        }
        results.append(("interface cues are distinct", waves.count == InterfaceSounds.Cue.allCases.count))
        let effects = InterfaceSounds()
        results.append(("automated interface-sound previews remain silent", !effects.preview()))
        return results
    }

    /// Exercise real control targets without showing a window or signing in.
    /// Restore the app's preferences even when an assertion fails.
    static func checkSettings(_ settings: SettingsController) -> [(String, Bool)] {
        let defaults = UserDefaults.standard
        let keys = [InterfaceSoundPreferences.enabledKey, InterfaceSoundPreferences.volumeKey,
                    InkSounds.preferenceKey, "notifications"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            settings.app.interfaceSounds.configure()
            settings.reloadGeneralControls()
        }
        defaults.removeObject(forKey: InterfaceSoundPreferences.enabledKey)
        defaults.removeObject(forKey: InterfaceSoundPreferences.volumeKey)
        settings.reloadGeneralControls()
        settings.window?.contentView?.layoutSubtreeIfNeeded()
        var results = [("interface sounds start off with a quiet adjustable preview", settings.interfaceSounds.state == .off && settings.interfaceSoundVolume.doubleValue == InterfaceSoundPreferences.defaultVolume && settings.interfaceSoundPreview.isEnabled)]
        let previousInk = defaults.object(forKey: InkSounds.preferenceKey) as? Bool
        let previousNotifications = defaults.object(forKey: "notifications") as? Bool
        settings.interfaceSounds.state = .on; settings.interfaceSoundVolume.doubleValue = 0.2
        let toggled = settings.interfaceSounds.sendAction(settings.interfaceSounds.action, to: settings.interfaceSounds.target)
        results.append(("interface controls persist independently of send and notification sounds", toggled && defaults.bool(forKey: InterfaceSoundPreferences.enabledKey) && settings.interfaceSoundVolumeLabel.stringValue == "20%" && defaults.object(forKey: InkSounds.preferenceKey) as? Bool == previousInk && defaults.object(forKey: "notifications") as? Bool == previousNotifications))
        let previewed = settings.interfaceSoundPreview.sendAction(settings.interfaceSoundPreview.action, to: settings.interfaceSoundPreview.target)
        results.append(("interface preview has a working target but stays silent in automation", previewed && !settings.app.interfaceSounds.preview()))
        settings.interfaceSoundVolume.doubleValue = 0
        let muted = settings.interfaceSoundVolume.sendAction(settings.interfaceSoundVolume.action, to: settings.interfaceSoundVolume.target)
        results.append(("zero interface volume disables the preview", muted && !settings.interfaceSoundPreview.isEnabled && settings.interfaceSoundVolumeLabel.stringValue == "0%"))
        results.append(("interface sound controls have native accessible labels", settings.interfaceSoundVolume.accessibilityLabel() == "Interface sound volume" && settings.interfaceSoundPreview.accessibilityLabel() == "Preview interface sound"))
        return results
    }
}
