import AppKit
import NevermoreCore
import OSLog

/// Local, opt-in interface feedback. Observe only this process's AppKit
/// notifications, never global input or incoming chat events.
@MainActor final class InterfaceSounds: NSObject {
    enum Cue: CaseIterable { case menu, selection, open, close }

    private static let logger = Logger(subsystem: "ch.goodvantage.Nevermore", category: "InterfaceSounds")
    private static let isAutomated = ProcessInfo.processInfo.arguments.contains {
        ["--self-check", "--performance-check", "--check-ui-sounds", "--check-ui-sound-settings"].contains($0)
    }
    private var isObserving = false
    private let knownWindows = NSHashTable<NSWindow>.weakObjects()
    private var sounds: [Cue: NSSound] = [:]
    private var playing: NSSound?
    private var gate = InterfaceSoundGate()

    var preferences: InterfaceSoundPreferences {
        let defaults = UserDefaults.standard
        return InterfaceSoundPreferences(
            enabled: defaults.object(forKey: InterfaceSoundPreferences.enabledKey) as? Bool,
            volume: defaults.object(forKey: InterfaceSoundPreferences.volumeKey) as? Double)
    }

    /// Disabled by default, with no observers or synthesized buffers until
    /// enabled (or explicitly previewed). Existing ink sounds are independent.
    func configure() {
        let preferences = preferences
        guard preferences.isEnabled, preferences.volume > 0, !Self.isAutomated else { stop(); return }
        playing?.volume = Float(preferences.volume)
        guard !isObserving else { return }
        isObserving = true
        for window in NSApp?.windows ?? [] where Self.isInterfaceWindow(window) {
            knownWindows.add(window)
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuAction), name: NSMenu.didSendActionNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(resignedActive), name: NSApplication.didResignActiveNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        isObserving = false
        knownWindows.removeAllObjects()
        playing?.stop()
        playing = nil
        gate = InterfaceSoundGate()
    }

    @discardableResult func play(_ cue: Cue) -> Bool {
        request(cue, context: .interaction)
    }

    /// Preview is an explicit foreground request, not an implicit opt-in.
    @discardableResult func preview() -> Bool {
        request(.selection, context: .preview)
    }

    private func request(_ cue: Cue, context requestedContext: InterfaceSoundGate.Context) -> Bool {
        let context: InterfaceSoundGate.Context
        if Self.isAutomated { context = .automation }
        else if NSApp?.isActive != true { context = .background }
        else {
            if case .interaction = requestedContext, !Self.hasRecentInput { return false }
            context = requestedContext
        }
        let preferences = preferences
        // Drop bursts instead of queuing or layering decorative audio.
        guard playing?.isPlaying != true,
              gate.accept(preferences: preferences, context: context, at: ProcessInfo.processInfo.systemUptime) else { return false }
        let sound: NSSound
        if let cached = sounds[cue] { sound = cached }
        else {
            guard let decoded = NSSound(data: Self.audioData(for: cue)) else {
                Self.logger.error("Could not decode synthesized interface audio; leaving the action silent.")
                return false
            }
            sounds[cue] = decoded
            sound = decoded
        }
        sound.volume = Float(preferences.volume)
        guard sound.play() else {
            Self.logger.error("Could not play interface audio; leaving the action silent.")
            return false
        }
        playing = sound
        return true
    }

    /// Reuse Nevermore's original, Unlicensed sine/noise synthesis. No audio
    /// from Xounds, macOS or third-party sound packs is copied or downloaded.
    static func audioData(for cue: Cue) -> Data {
        let ink: InkSounds.Cue = switch cue {
        case .menu: .land
        case .selection: .stick
        case .open: .lift
        case .close: .takeBack
        }
        return InkSounds.wave(InkSounds.samples(for: ink))
    }

    private static var hasRecentInput: Bool {
        guard let event = NSApp?.currentEvent else { return false }
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return false }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: break
        default: return false
        }
        // currentEvent can outlive its dispatch. Do not let stale input make
        // a later restoration, network callback or cleanup sound interactive.
        let age = ProcessInfo.processInfo.systemUptime - event.timestamp
        return age >= 0 && age < 0.5
    }

    private static func isInterfaceWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && window.windowController != nil
    }

    @objc private func menuOpened(_ notification: Notification) { play(.menu) }
    @objc private func menuAction(_ notification: Notification) { play(.selection) }
    @objc private func resignedActive(_ notification: Notification) { playing?.stop() }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isInterfaceWindow(window), !knownWindows.contains(window) else { return }
        knownWindows.add(window)
        play(.open)
    }

    @objc private func windowClosing(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let wasVisible = knownWindows.contains(window) && window.isVisible
        knownWindows.remove(window)
        if wasVisible { play(.close) }
    }
}
