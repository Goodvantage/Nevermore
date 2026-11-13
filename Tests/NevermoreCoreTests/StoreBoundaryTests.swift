import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Test func staleVisitWithIdenticalTimestampCannotCompleteNewGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AccountStore(directory: directory)
    try await store.pendingVisit(channelID: "a", timestamp: "2026-11-07 10:00:00.123456")
    let old = try #require(await store.visitSnapshots().first)
    try await store.markUnread(channelID: "a")
    try await store.pendingVisit(channelID: "a", timestamp: old.timestamp)
    try await store.completeVisit(channelID: "a", timestamp: old.timestamp, generation: old.generation)
    #expect(try await store.visits()["a"] == old.timestamp)
}
@Test func changedSharedDraftCannotBeAcceptedUnderOldEditorSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AccountStore(directory: directory)
    let before = Draft(channelID: "a", html: "<p>Before</p>")
    try await store.saveDraft(before)
    let after = Draft(channelID: "a", html: "<p>Changed in the other window</p>")
    try await store.saveDraft(after)
    await #expect(throws: (any Error).self) { try await store.acceptDraft(channelID: "a", expected: before) }
    #expect(try await store.draft(channelID: "a") == after)
    #expect(try await store.operations().isEmpty)
}
@Test func stagingCopiesSymlinkTargetRatherThanPersistingExternalReference() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source.txt"), link = directory.appendingPathComponent("link.txt")
    try Data("Private file".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    let store = try AccountStore(directory: directory.appendingPathComponent("account"))
    let staged = try await store.stage(file: link)
    try Data("Changed after staging".utf8).write(to: source)
    #expect(try String(contentsOfFile: staged.localPath, encoding: .utf8) == "Private file")
    #expect(try FileManager.default.attributesOfItem(atPath: staged.localPath)[.type] as? FileAttributeType == .typeRegular)
}

@Test func simultaneousStagingCannotExceedAccountBudget() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("file.dat")
    try Data(repeating: 42, count: 20_000).write(to: source)
    let store = try AccountStore(directory: directory.appendingPathComponent("account"))
    await store.setMaxStagingBytes(30_000)
    async let first = try? store.stage(file: source)
    async let second = try? store.stage(file: source)
    let values = await [first, second]
    #expect(values.compactMap { $0 }.count == 1)
}

@Test func sentStagingIsReclaimedOnlyAfterOtherDraftReferencesAreReleased() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("file.txt")
    try Data("Attachment".utf8).write(to: source)
    let store = try AccountStore(directory: directory.appendingPathComponent("account"))
    let file = try await store.stage(file: source)
    try await store.saveDraft(Draft(channelID: "a", html: "<p>Caption</p>", attachments: [file]))
    let operation = try await store.acceptDraft(channelID: "a")
    try await store.saveDraft(Draft(channelID: "b", attachments: [file]))
    let message = RavenMessage(raw: .object(["name": .string("accepted"), "channel_id": .string("a"), "creation": .string("2026-11-07 10:00:00.000001"), "message_batch_id": .string(operation.id.uuidString)]))
    try await store.acknowledge(id: operation.id, messages: [message])
    #expect(FileManager.default.fileExists(atPath: file.localPath))
    try await store.saveDraft(Draft(channelID: "b"))
    try await store.pruneStaging()
    #expect(!FileManager.default.fileExists(atPath: file.localPath))
}
