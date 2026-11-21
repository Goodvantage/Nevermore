import Testing
@testable import NevermoreCore

@Test func recentIdentifiersForgetTheOldestBeyondCapacity() {
    var recent = RecentIdentifiers(capacity: 3)
    let fresh = ["a", "b", "c"].map { recent.insert($0) }
    let repeated = recent.insert("b")
    let fourth = recent.insert("d")
    #expect(fresh == [true, true, true] && !repeated && fourth)
    #expect(!recent.contains("a") && recent.contains("b") && recent.contains("c") && recent.contains("d"))
    #expect(recent.count == 3)
}

@Test func removedIdentifiersCanBeInsertedAgain() {
    var recent = RecentIdentifiers(capacity: 2)
    recent.insert("a"); recent.insert("b")
    recent.remove("a")
    #expect(!recent.contains("a") && recent.count == 1)
    let again = recent.insert("a"), third = recent.insert("c")
    #expect(again && third)
    #expect(!recent.contains("b") && recent.contains("a") && recent.contains("c"))
}
