import Foundation

/// The glyph of the optional menu bar item. The app draws each one; this
/// enum names them and reads the stored choice.
public enum MenuBarIcon: String, Sendable, CaseIterable {
    case raven, ravenHead, feather, bird, speechBubbles

    public static let defaultsKey = "menuBarIcon"
    public static let standard = MenuBarIcon.raven

    /// An unset value, or one written by a version that knew other icons,
    /// reads as the standard raven.
    public init(storedValue: String?) {
        self = storedValue.flatMap(MenuBarIcon.init(rawValue:)) ?? .standard
    }
}

/// Which key sends a message from the composer. Command-Return sends and
/// Shift-Return inserts a new line under either choice; the choice only
/// decides what an unmodified Return does.
public enum ComposerSendKey: Sendable, CaseIterable {
    case returnKey, commandReturn

    /// The choice is stored as this Boolean, which the composer reads on
    /// each Return and which predates the enum.
    public static let defaultsKey = "returnNewline"

    public init(returnInsertsNewline: Bool) {
        self = returnInsertsNewline ? .commandReturn : .returnKey
    }

    public var returnInsertsNewline: Bool { self == .commandReturn }
}
