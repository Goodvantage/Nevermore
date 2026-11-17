import Foundation

public struct ConversationLocation: Codable, Sendable, Equatable {
    public var channelID: String
    public var anchorMessageID: String?
    public var pixelOffset: Double
    public var threadParentChannelID: String?
    public var searchText: String
    public init(channelID: String, anchorMessageID: String? = nil, pixelOffset: Double = 0, searchText: String = "", threadParentChannelID: String? = nil) {
        self.channelID = channelID; self.anchorMessageID = anchorMessageID; self.pixelOffset = pixelOffset.isFinite ? pixelOffset : 0; self.searchText = searchText; self.threadParentChannelID = threadParentChannelID
    }
}
/// A place Back and Forward return to: a conversation, or the search
/// results screen with the search it showed.
public enum NavigationEntry: Codable, Sendable, Equatable {
    case conversation(ConversationLocation)
    case search(SearchCriteria)

    public var location: ConversationLocation? { if case .conversation(let location) = self { return location }; return nil }
}
public struct NavigationHistory: Codable, Sendable, Equatable {
    public private(set) var entries: [NavigationEntry] = []
    public private(set) var index = -1
    public static let limit = 50
    public init() {}
    public var currentEntry: NavigationEntry? { entries.indices.contains(index) ? entries[index] : nil }
    /// The current entry when it is a conversation.
    public var current: ConversationLocation? { currentEntry?.location }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index + 1 < entries.count }
    public mutating func capture(_ location: ConversationLocation) {
        guard let current, current.channelID == location.channelID else { return }
        entries[index] = .conversation(location)
    }
    public mutating func visit(_ location: ConversationLocation) {
        if current?.channelID == location.channelID { capture(location); return }
        push(.conversation(location))
    }
    /// Records the search the results screen shows. Refining the search
    /// replaces the current search entry rather than adding one per change.
    public mutating func visitSearch(_ criteria: SearchCriteria) {
        if case .search = currentEntry { entries[index] = .search(criteria); return }
        push(.search(criteria))
    }
    public mutating func back() -> NavigationEntry? { guard canGoBack else { return nil }; index -= 1; return currentEntry }
    public mutating func forward() -> NavigationEntry? { guard canGoForward else { return nil }; index += 1; return currentEntry }
    private mutating func push(_ entry: NavigationEntry) {
        entries = Array(entries.prefix(index + 1)); entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }
}
public struct SavedWindowState: Codable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Equatable {
        public var x: Double; public var y: Double; public var width: Double; public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
        public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width >= 650 && height >= 420 && width <= 20_000 && height <= 20_000 }
    }
    public var version = 1
    public var windowID: UUID
    public var accountID: UUID
    public var location: ConversationLocation
    public var workspaceID: String?
    public var frame: Frame?
    public var threadRootID: String?
    /// The window ID of the first tab when this window was one of several
    /// tabs. Absent in states written before tab restoration existed.
    public var tabGroupID: UUID?
    public init(windowID: UUID, accountID: UUID, location: ConversationLocation, workspaceID: String? = nil, frame: Frame? = nil, threadRootID: String? = nil, tabGroupID: UUID? = nil) {
        self.windowID = windowID; self.accountID = accountID; self.location = location; self.workspaceID = workspaceID; self.frame = frame; self.threadRootID = threadRootID; self.tabGroupID = tabGroupID
    }
}
