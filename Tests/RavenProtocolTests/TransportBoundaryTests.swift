import Foundation
import Synchronization
import Testing
@testable import RavenProtocol

extension TransportSuite {
    @Test func oversizedTokenGrantIsRejected() async throws {
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Length": "1000000000"])!, Data("{}".utf8))
        }
        await #expect(throws: RavenError.resourceLimit(1024 * 1024)) {
            try await RavenClient.exchange(origin: URL(string: "https://site.test")!, clientID: "client", redirectURI: URL(string: "ch.goodvantage.Nevermore://oauth")!, code: "code", verifier: "verifier", session: session)
        }
    }

    @Test func streamedOversizedTokenGrantIsRejected() async throws {
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!, Data(repeating: 65, count: 1024 * 1024 + 1))
        }
        await #expect(throws: RavenError.resourceLimit(1024 * 1024)) {
            try await RavenClient.exchange(origin: URL(string: "https://site.test")!, clientID: "client", redirectURI: URL(string: "ch.goodvantage.Nevermore://oauth")!, code: "code", verifier: "verifier", session: session)
        }
    }

    @Test func stagedUploadPreservesOriginalFilenameAndRejectsHeaderControls() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("image fixture".utf8).write(to: file)
        let session = StubURLProtocol.install { request in
            let body = String(decoding: stubBody(request), as: UTF8.self)
            #expect(body.contains("filename=\"Photo.png\""))
            return stubResponse(request, 200, #"{"message":{"file_url":"/private/files/Photo.png","file_size":13}}"#)
        }
        _ = try await client(session, tokens: validTokens).upload(file: file, filename: "Photo.png")
    }
    @Test func declaredOversizedResponseIsRejectedBeforeAccumulation() async throws {
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["Content-Length":"1000000000"])!, Data("{}".utf8))
        }
        await #expect(throws: RavenError.resourceLimit(8 * 1024 * 1024)) { try await client(session).rpc("raven.api.native.boot") }
    }
    @Test func declaredOversizedForbiddenResponseReportsHTTPStatus() async throws {
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/2", headerFields: ["Content-Length":"1000000000"])!, Data(#"{"exc_type":"PermissionError"}"#.utf8))
        }
        await #expect(throws: RavenError.http(403, "PermissionError")) { try await client(session, tokens: validTokens).rpc("raven.api.native.boot") }
    }
    @Test func streamedOversizedErrorBodyKeepsHTTPStatusWithoutResourceLimit() async throws {
        let session = StubURLProtocol.install { request in
            let body = Data(#"{"exc_type":"PermissionError"}"#.utf8) + Data(repeating: 65, count: 1024 * 1024)
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/2", headerFields: nil)!, body)
        }
        // The body is truncated at the classification cap, but the valid JSON
        // prefix still classifies — and never becomes a resource limit.
        await #expect(throws: RavenError.http(403, "PermissionError")) { try await client(session, tokens: validTokens).rpc("raven.api.native.boot") }
    }
    @Test func errorBodyTruncatedMidObjectYieldsNilKindButKeepsStatus() async throws {
        let session = StubURLProtocol.install { request in
            let large = Data(#"{"exc_type":"PermissionError","message":""#.utf8) + Data(repeating: 65, count: 1024 * 1024)
            let truncated = large.prefix(64 * 1024)
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: "HTTP/2", headerFields: nil)!, Data(truncated))
        }
        await #expect(throws: RavenError.http(403, nil)) { try await client(session, tokens: validTokens).rpc("raven.api.native.boot") }
    }
    @Test func oversizedTokenGrantErrorReportsOAuthCode() async throws {
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/2", headerFields: ["Content-Length": "1000000000"])!, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        await #expect(throws: RavenError.oauth("invalid_grant")) {
            try await RavenClient.exchange(origin: URL(string: "https://site.test")!, clientID: "client", redirectURI: URL(string: "ch.goodvantage.Nevermore://oauth")!, code: "code", verifier: "verifier", session: session)
        }
    }
    @Test(.enabled(if: TestKeychain.isWritable, TestKeychain.unavailableReason)) func declaredOversizedUnauthorizedResponseTriggersRefreshAndRetry() async throws {
        let calls = Mutex<[String]>([])
        let session = StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            calls.withLock { $0.append(path) }
            if path.contains("get_token") {
                return stubResponse(request, 200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600,"token_type":"Bearer"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" {
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/2", headerFields: ["Content-Length": "1000000000"])!, Data(#"{"exc_type":"AuthenticationError"}"#.utf8))
            }
            return stubResponse(request, 200, #"{"message":{"ok":true}}"#)
        }
        let result = try await client(session, tokens: validTokens).rpc("raven.api.native.boot")
        #expect(result["ok"] == .bool(true))
        let paths = calls.withLock { $0 }
        #expect(paths.filter { $0.contains("get_token") }.count == 1)
        #expect(paths.filter { !$0.contains("get_token") }.count == 2)
    }
    @Test(.enabled(if: TestKeychain.isWritable, TestKeychain.unavailableReason)) func refreshCompletionAfterLogoutCannotRestoreKeychainCredentials() async throws {
        let id = UUID()
        defer { try? KeychainTokenStore.delete(accountID: id) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = Mutex(false)
        let session = StubURLProtocol.install { request in
            if request.url!.path.contains("get_token") {
                started.withLock { $0 = true }; _ = gate.wait(timeout: .now() + 5)
                return stubResponse(request, 200, #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#)
            }
            return stubResponse(request, 200, #"{"message":true}"#)
        }
        try KeychainTokenStore.save(expiredTokens, accountID: id)
        let c = RavenClient(origin: URL(string: "https://site.test")!, tokens: expiredTokens, clientID: "client", accountID: id, session: session)
        let request = Task { try await c.rpc("raven.api.native.boot") }
        for _ in 0..<200 { if started.withLock({ $0 }) { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(started.withLock { $0 })
        let logout = Task { await c.revoke() }
        for _ in 0..<200 { if await c.tokens == nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await c.tokens == nil)
        try KeychainTokenStore.delete(accountID: id)
        gate.signal(); await logout.value
        do { _ = try await request.value; Issue.record("A request completed after local logout") } catch { }
        #expect(try KeychainTokenStore.load(accountID: id) == nil)
        #expect(await c.tokens == nil)
    }
}
