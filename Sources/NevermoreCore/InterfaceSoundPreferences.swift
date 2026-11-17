/// Local interface sounds start off. The app owns storage; Core resolves
/// stored values without depending on UserDefaults or AppKit.
public struct InterfaceSoundPreferences: Equatable, Sendable {
    public static let enabledKey = "interfaceSounds"
    public static let volumeKey = "interfaceSoundVolume"
    public static let defaultVolume = 0.35

    public let isEnabled: Bool
    public let volume: Double

    /// - Parameters:
    ///   - enabled: Stored on/off flag; `nil` (nothing stored) means off.
    ///   - volume: Stored volume; `nil` or non-finite means `defaultVolume`,
    ///     while finite values are clamped to `0...1`.
    public init(enabled: Bool? = nil, volume: Double? = nil) {
        self.isEnabled = enabled ?? false
        if let volume, volume.isFinite {
            self.volume = min(1, max(0, volume))
        } else {
            self.volume = Self.defaultVolume
        }
    }
}

/// Pure playback policy, owned by the app's main-actor audio service.
/// Preview is explicit opt-in even while effects are disabled. All cues
/// share a cooldown; suppressed requests never advance it.
public struct InterfaceSoundGate: Sendable {
    /// Why a sound is about to play.
    public enum Context: Sendable {
        /// A foreground user interaction; requires `isEnabled`.
        case interaction
        /// An explicit foreground preview, independent of `isEnabled`.
        case preview
        /// Activity while the app is backgrounded; always suppressed.
        case background
        /// Automated activity; always suppressed.
        case automation
    }

    /// Minimum seconds between two accepted plays, shared across contexts.
    private static let minimumInterval: Double = 0.12

    /// Uptime of the last accepted play; only acceptance writes it.
    private var lastAcceptedUptime: Double?

    public init() {}

    /// `uptime` is monotonic seconds. Invalid or backwards times fail closed.
    public mutating func accept(preferences: InterfaceSoundPreferences, context: Context, at uptime: Double) -> Bool {
        guard uptime.isFinite, uptime >= 0 else { return false }
        switch context {
        case .automation, .background:
            return false
        case .interaction:
            guard preferences.isEnabled else { return false }
        case .preview:
            break
        }
        guard preferences.volume > 0 else { return false }
        if let last = lastAcceptedUptime {
            guard uptime >= last, uptime - last >= Self.minimumInterval else { return false }
        }
        lastAcceptedUptime = uptime
        return true
    }
}
