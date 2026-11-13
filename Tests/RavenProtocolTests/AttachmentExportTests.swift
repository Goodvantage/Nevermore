import Foundation
import Testing
@testable import RavenProtocol

struct AttachmentExportTests {
    private func fixture() throws -> (URL, DownloadedAttachment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreExportTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let privateFolder = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let source = privateFolder.appendingPathComponent("report.txt")
        try Data("complete download".utf8).write(to: source)
        return (root, DownloadedAttachment(url: source, directory: privateFolder, contentType: "text/plain", byteCount: 17, origin: URL(string: "https://site.test/private/file?secret=discarded")!))
    }
    @Test func exportsAreQuarantinedAndRefuseExistingDestinations() throws {
        let (root, artifact) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("saved.txt")
        try artifact.export(to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "complete download")
        #expect(try target.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
        #expect(throws: (any Error).self) { try artifact.export(to: target) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "complete download")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["private", "saved.txt"])
    }
    @Test func confirmedReplacementNeverFollowsADestinationSymlink() throws {
        let (root, artifact) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("original.txt"), target = root.appendingPathComponent("chosen.txt")
        try Data("preserve original".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try artifact.export(to: target) }
        try artifact.export(to: target, replacing: true)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve original")
        #expect(try String(contentsOf: target, encoding: .utf8) == "complete download")
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeRegular)
    }
    @Test func failedPublicationLeavesThePreviousFileAndNoPartialExport() throws {
        let (root, artifact) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("saved.txt")
        try Data("previous file".utf8).write(to: target)
        try FileManager.default.removeItem(at: artifact.url)
        #expect(throws: (any Error).self) { try artifact.export(to: target, replacing: true) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "previous file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["private", "saved.txt"])
    }
}
