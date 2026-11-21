import Foundation

/// The most recent identifiers, up to a capacity: inserting past it forgets
/// the oldest, so recent history survives where a reset would forget it.
public struct RecentIdentifiers: Sendable, Equatable {
    public let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    public init(capacity: Int) {
        precondition(capacity > 0, "RecentIdentifiers needs room for at least one identifier")
        self.capacity = capacity
    }

    public var count: Int { members.count }
    public func contains(_ id: String) -> Bool { members.contains(id) }

    /// Adds `id` as the newest. False when it was already present.
    @discardableResult public mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity { members.remove(order.removeFirst()) }
        return true
    }

    public mutating func remove(_ id: String) {
        guard members.remove(id) != nil else { return }
        order.removeAll { $0 == id }
    }
}
