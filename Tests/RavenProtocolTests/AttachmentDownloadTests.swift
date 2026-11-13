import Foundation
import CoreServices
import Testing
import Synchronization
@testable import RavenProtocol

extension TransportSuite {
    @Test func releasingDownloadKeepsSharedAccountDirectoryForSiblingCreation() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!, Data("fixture".utf8))
        }
        let accountID = UUID()
        let raven = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture", accountID: accountID, session: session)
        var attachment: DownloadedAttachment? = try await raven.download(URL(string: "https://site.test/file.txt")!, to: root)
        let file = try #require(attachment?.url)
        let accountDirectory = DownloadedAttachment.cacheDirectory(accountID: accountID, in: root)
        attachment = nil

        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Another download can already have ensured the shared parent exists
        // when this file's last owner releases it, before creating its child.
        let sibling = accountDirectory.appendingPathComponent("next-download", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: accountDirectory.path) == ["next-download"])
        try DownloadedAttachment.purgeDownloads(accountID: accountID, in: root)
        #expect(!FileManager.default.fileExists(atPath: accountDirectory.path))
    }

    @Test func failedDownloadKeepsSharedAccountDirectoryForSiblingCreation() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = StubURLProtocol.install { request in stubResponse(request, 403, #"{"exc_type":"PermissionError"}"#) }
        let accountID = UUID()
        let raven = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture", accountID: accountID, session: session)
        await #expect(throws: RavenError.http(403, "PermissionError")) { try await raven.download(URL(string: "https://site.test/file.txt")!, to: root) }

        let accountDirectory = DownloadedAttachment.cacheDirectory(accountID: accountID, in: root)
        let sibling = accountDirectory.appendingPathComponent("next-download", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: accountDirectory.path) == ["next-download"])
    }

    @Test func invalidAttachmentPathsAreRejectedBeforeNetworkOrDiskUse() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let requests = Mutex(0)
        let session = StubURLProtocol.install { request in
            requests.withLock { $0 += 1 }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!, Data("site page".utf8))
        }
        let raven = client(session)
        await #expect(throws: RavenError.invalidResponse) { try await raven.download(URL(string: "https://site.test/")!) }
        await #expect(throws: RavenError.invalidResponse) { try await raven.download(URL(string: "https://site.test/?download=1")!, to: root) }
        #expect(requests.withLock { $0 } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func removingPrivateDownloadsIsIsolatedByAccount() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Type": "text/plain"])!, Data("fixture".utf8))
        }
        let firstID = UUID(), secondID = UUID()
        let first = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture", accountID: firstID, session: session)
        let second = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture", accountID: secondID, session: session)
        let one = try await first.download(URL(string: "https://site.test/file.txt")!, to: root)
        let two = try await second.download(URL(string: "https://site.test/file.txt")!, to: root)
        try DownloadedAttachment.purgeDownloads(accountID: firstID, in: root)
        #expect(!FileManager.default.fileExists(atPath: one.url.path))
        #expect(try String(contentsOf: two.url, encoding: .utf8) == "fixture")
        #expect(throws: (any Error).self) { try one.export(to: root.appendingPathComponent("denied.txt")) }
        try DownloadedAttachment.purgeDownloads(accountID: firstID, in: root)
    }

    @Test func activeDownloadBudgetIncludesPreviewsAndReleasesFailedReservations() throws {
        var leases = try (0..<8).map { _ in try AttachmentDownloadLease(maximumBytes: 64 * 1024 * 1024) }
        #expect(throws: (any Error).self) { try AttachmentDownloadLease(maximumBytes: 1) }
        #expect(throws: (any Error).self) { try AttachmentDownloadLease(maximumBytes: 1) }
        leases.removeLast()
        leases.append(try AttachmentDownloadLease(maximumBytes: 64 * 1024 * 1024))
        #expect(leases.count == 8)
    }
    private func downloadDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreDownloadTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func expectNoPrivateFiles(in root: URL) throws {
        for accountDirectory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            #expect(accountDirectory.lastPathComponent.hasPrefix("NevermoreDownloads-"))
            #expect(try accountDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: accountDirectory.path).isEmpty)
        }
    }

    @Test func downloadsProduceCompleteQuarantinedFilesAndDeleteAfterLastOwner() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 42, count: 1024 * 1024)
        let session = StubURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Type": "text/plain", "Content-Length": String(data.count), "Content-Disposition": "attachment; filename=\"payload.part\""])!, data)
        }
        var artifact: DownloadedAttachment? = try await client(session, tokens: validTokens).download(URL(string: "https://site.test/private/files/file.txt?token=private")!, to: root)
        let file = try #require(artifact?.url)
        #expect(artifact?.byteCount == data.count)
        #expect(artifact?.filename == "payload.part")
        #expect(try Data(contentsOf: file) == data)
        let properties = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(properties != nil)
        let rawOrigin = properties?[kLSQuarantineOriginURLKey as String]
        let safeOrigin = (rawOrigin as? URL) ?? (rawOrigin as? String).flatMap(URL.init(string:))
        // Launch Services may omit optional provenance when reading the file
        // back. Any provenance it does expose must remain credential-free.
        #expect(rawOrigin == nil || (safeOrigin?.host == "site.test" && safeOrigin?.query == nil && safeOrigin?.path.isEmpty == true))
        #expect(properties?[kLSQuarantineAgentNameKey as String] as? String == "Nevermore")
        #expect(properties?[kLSQuarantineDataURLKey as String] == nil)
        weak var owner = artifact
        artifact = nil
        #expect(owner == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try expectNoPrivateFiles(in: root)
    }

    @Test func streamedUnknownLengthBodiesCannotExceedTheBudget() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!, Data(repeating: 1, count: 4096))
        }
        await #expect(throws: RavenError.resourceLimit) { try await client(session).download(URL(string: "https://site.test/private/files/large")!, to: root, maximumBytes: 512) }
        try expectNoPrivateFiles(in: root)
    }

    @Test func declaredOversizedFilesAndPartialResponsesLeaveNoArtifact() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let oversized = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Length": "1000000"])!, Data())
        }
        await #expect(throws: RavenError.resourceLimit) { try await client(oversized).download(URL(string: "https://site.test/file")!, to: root, maximumBytes: 512) }
        try expectNoPrivateFiles(in: root)
        let partial = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/2", headerFields: ["Content-Range": "bytes 0-2/10"])!, Data("abc".utf8))
        }
        await #expect(throws: RavenError.invalidResponse) { try await client(partial).download(URL(string: "https://site.test/file")!, to: root) }
        try expectNoPrivateFiles(in: root)
    }

    @Test func rejectedAndCrossOriginDownloadsNeverLeaveFilesOrForwardCredentials() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = StubURLProtocol.install { request in stubResponse(request, 403, #"{"exc_type":"PermissionError","message":"private content"}"#) }
        await #expect(throws: RavenError.http(403, "PermissionError")) { try await client(session).download(URL(string: "https://site.test/file")!, to: root) }
        await #expect(throws: RavenError.crossOrigin) { try await client(session, tokens: validTokens).download(URL(string: "https://other.test/file")!, to: root) }
        try expectNoPrivateFiles(in: root)
    }

    @Test(.enabled(if: TestKeychain.isWritable, TestKeychain.unavailableReason)) func streamedDownloadRetries401WithTheSingleFlightTokenGrant() async throws {
        let root = try downloadDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let account = UUID(); defer { try? KeychainTokenStore.delete(accountID: account) }
        let refreshes = Mutex(0)
        let session = StubURLProtocol.install { request in
            if request.url!.path == RavenEndpoints.tokenPath {
                refreshes.withLock { $0 += 1 }
                return stubResponse(request, 200, #"{"access_token":"fresh","refresh_token":"next","expires_in":3600}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" { return stubResponse(request, 401, "{}") }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Type": "text/plain"])!, Data("complete".utf8))
        }
        let raven = RavenClient(origin: URL(string: "https://site.test")!, tokens: validTokens, clientID: "client-1", accountID: account, session: session)
        let result = try await raven.download(URL(string: "https://site.test/file.txt")!, to: root)
        #expect(try String(contentsOf: result.url, encoding: .utf8) == "complete")
        #expect(refreshes.withLock { $0 } == 1)
    }

    @Test func downloadedNamesCannotCreatePathsHiddenFilesOrOversizedComponents() {
        #expect(DownloadedAttachment.safeFilename("../../report.txt") == "report.txt")
        #expect(DownloadedAttachment.safeFilename("folder\\report.txt") == "report.txt")
        #expect(!DownloadedAttachment.safeFilename(".profile").hasPrefix("."))
        #expect(!DownloadedAttachment.safeFilename("bad\r\nname").contains("\n"))
        #expect(DownloadedAttachment.safeFilename(String(repeating: "🙂", count: 100)).utf8.count <= 200)
        #expect(DownloadedAttachment.safeFilename("." + String(repeating: "x", count: 300)).utf8.count <= 200)
    }
}
