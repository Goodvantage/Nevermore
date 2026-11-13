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
public struct NavigationHistory: Codable, Sendable, Equatable {
    public private(set) var entries: [ConversationLocation] = []
    public private(set) var index = -1
    public static let limit = 50
    public init() {}
    public var current: ConversationLocation? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index + 1 < entries.count }
    public mutating func capture(_ location: ConversationLocation) {
        guard entries.indices.contains(index), entries[index].channelID == location.channelID else { return }
        entries[index] = location
    }
    public mutating func visit(_ location: ConversationLocation) {
        if current?.channelID == location.channelID { capture(location); return }
        entries = Array(entries.prefix(index + 1)); entries.append(location)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }
    public mutating func back() -> ConversationLocation? { guard canGoBack else { return nil }; index -= 1; return current }
    public mutating func forward() -> ConversationLocation? { guard canGoForward else { return nil }; index += 1; return current }
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
