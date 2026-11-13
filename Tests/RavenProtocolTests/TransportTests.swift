import Foundation
import Synchronization
import Testing
@testable import RavenProtocol

/// In-memory request stub: the handler decides every response synchronously.
/// Serialized so the shared handler is never observed mid-swap.
final class StubURLProtocol: URLProtocol {
    typealias Stub = (URLRequest) throws -> (HTTPURLResponse, Data)
    nonisolated(unsafe) static var handler: Stub = { request in
        Issue.record("Unstubbed request to \(request.url?.absoluteString ?? "nil")")
        return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/2", headerFields: nil)!, Data())
    }

    static func install(_ stub: @escaping Stub) -> URLSession {
        handler = stub
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration, delegate: RavenClient.SameOriginRedirectDelegate(), delegateQueue: nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

func stubResponse(_ request: URLRequest, _ status: Int, _ json: String) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: ["Content-Type": "application/json"])!, Data(json.utf8))
}

func stubBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 8192)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

func formFields(_ request: URLRequest) -> [String: String] {
    Dictionary(URLComponents(string: "?" + (String(decoding: stubBody(request), as: UTF8.self)))?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
}

func client(_ session: URLSession, tokens: OAuthTokens? = nil) -> RavenClient {
    RavenClient(origin: URL(string: "https://site.test")!, tokens: tokens, clientID: "client-1", accountID: UUID(), session: session)
}

let validTokens = OAuthTokens(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600))
let expiredTokens = OAuthTokens(accessToken: "access-old", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(-60))

@Suite(.serialized)
struct TransportSuite {

    @Test func readsSendGetWithQueryArgumentsAndBearer() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let session = StubURLProtocol.install { request in
            seen.withLock { $0 = request }
            return stubResponse(request, 200, #"{"message":{"messages":[{"name":"m1"}],"has_old_messages":true}}"#)
        }
        let result = try await client(session, tokens: validTokens).rpc("raven.api.chat_stream.get_messages", arguments: ["channel_id": .string("general"), "limit": .number(100), "update_last_visit": .bool(false)])
        #expect(result["messages"].array.first?["name"] == .string("m1"))
        let request = try #require(seen.withLock { $0 })
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/method/raven.api.chat_stream.get_messages")
        let query = request.url?.query ?? ""
        #expect(query.contains("channel_id=general"))
        #expect(query.contains("limit=100"))
        #expect(query.contains("update_last_visit=false"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.httpBody == nil)
    }

    @Test func mutationsPostJSONBodies() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let session = StubURLProtocol.install { request in
            seen.withLock { $0 = request }
            return stubResponse(request, 200, #"{"message":[{"name":"m9","channel_id":"general"}]}"#)
        }
        let result = try await client(session, tokens: validTokens).rpc("raven.api.raven_message.send_message_with_attachments", arguments: ["channel_id": .string("general"), "files": .array([]), "client_id": .string("uuid-1"), "is_reply": .bool(true)], mutation: true)
        #expect(result.array.first?["name"] == .string("m9"))
        let request = try #require(seen.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try? JSONDecoder().decode([String: JSONValue].self, from: stubBody(request)))
        #expect(body["channel_id"] == .string("general"))
        #expect(body["is_reply"] == .bool(true))
        #expect(request.url?.query == nil)
    }

    @Test func guestCallsCarryNoAuthorization() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let session = StubURLProtocol.install { request in
            seen.withLock { $0 = request }
            return stubResponse(request, 200, #"{"message":{"sitename":"site","raven_version":"3.2.0"}}"#)
        }
        let result = try await client(session).rpc("raven.api.raven_mobile.get_client_id")
        #expect(result["sitename"] == .string("site"))
        #expect(seen.withLock { $0?.value(forHTTPHeaderField: "Authorization") } == nil)
    }

    @Test func frappeExceptionsMapToStructuredErrors() async throws {
        let session = StubURLProtocol.install { request in
            stubResponse(request, 403, #"{"exc_type":"PermissionError","exception":"frappe.PermissionError: trace SECRET-traceback-xyz","_server_messages":"[]"}"#)
        }
        do {
            _ = try await client(session, tokens: validTokens).rpc("raven.api.chat_stream.get_messages", arguments: ["channel_id": .string("private")])
            Issue.record("expected throw")
        } catch let error as RavenError {
            #expect(error.isPermissionDenied)
            #expect(error.isPermanent)
            let text = error.localizedDescription
            #expect(text.contains("403") && text.contains("PermissionError"))
            #expect(!text.contains("SECRET-traceback-xyz") && !text.contains("frappe.PermissionError:"))
        }
    }

    @Test func transportFailuresStayRetryable() async throws {
        let session = StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await client(session, tokens: validTokens).rpc("raven.api.native.boot")
            Issue.record("expected throw")
        } catch let error as RavenError {
            #expect(error == .transport)
            #expect(!error.isPermanent)
        }
    }

    @Test func serverFailuresStayRetryable() async throws {
        let session = StubURLProtocol.install { request in stubResponse(request, 503, #"{"exc_type":"InternalError"}"#) }
        do {
            _ = try await client(session, tokens: validTokens).rpc("raven.api.native.boot")
            Issue.record("expected throw")
        } catch let error as RavenError {
            #expect(error == .http(503, "InternalError"))
            #expect(!error.isPermanent)
        }
    }

    @Test(.enabled(if: TestKeychain.isWritable, TestKeychain.unavailableReason)) func unauthorizedAnswerTriggersOneRefreshAndOneRetry() async throws {
        let calls = Mutex<[String]>([])
        let session = StubURLProtocol.install { request in
            let path = request.url?.path ?? ""
            calls.withLock { $0.append(path) }
            if path.contains("get_token") {
                #expect(request.httpMethod == "POST")
                let fields = formFields(request)
                #expect(fields["grant_type"] == "refresh_token" && fields["refresh_token"] == "refresh-1" && fields["client_id"] == "client-1")
                return stubResponse(request, 200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600,"token_type":"Bearer"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" {
                return stubResponse(request, 401, #"{"exc_type":"AuthenticationError"}"#)
            }
            return stubResponse(request, 200, #"{"message":{"ok":true}}"#)
        }
        let result = try await client(session, tokens: validTokens).rpc("raven.api.native.boot")
        #expect(result["ok"] == .bool(true))
        let paths = calls.withLock { $0 }
        #expect(paths.filter { $0.contains("get_token") }.count == 1)
        #expect(paths.filter { !$0.contains("get_token") }.count == 2)
    }

    @Test(.enabled(if: TestKeychain.isWritable, TestKeychain.unavailableReason)) func expiredTokensShareASingleFlightRefresh() async throws {
        let grants = Mutex(0)
        let session = StubURLProtocol.install { request in
            if request.url?.path.contains("get_token") == true {
                grants.withLock { $0 += 1 }
                return stubResponse(request, 200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
            return stubResponse(request, 200, #"{"message":{"ok":true}}"#)
        }
        let client = client(session, tokens: expiredTokens)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await client.rpc("raven.api.native.boot") } }
            try await group.waitForAll()
        }
        #expect(grants.withLock { $0 } == 1)
    }

    @Test func exchangePostsTheAuthorizationCodeGrant() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let session = StubURLProtocol.install { request in
            seen.withLock { $0 = request }
            return stubResponse(request, 200, #"{"access_token":"access-9","refresh_token":"refresh-9","expires_in":7200,"token_type":"Bearer","scope":"all openid"}"#)
        }
        let redirect = URL(string: "ch.goodvantage.Nevermore://oauth")!
        let tokens = try await RavenClient.exchange(origin: URL(string: "https://site.test")!, clientID: "client-1", redirectURI: redirect, code: "code-7", verifier: "verifier-8", session: session)
        #expect(tokens.accessToken == "access-9" && tokens.refreshToken == "refresh-9")
        #expect(tokens.expiresAt.timeIntervalSinceNow > 7000)
        let request = try #require(seen.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/method/frappe.integrations.oauth2.get_token")
        let fields = formFields(request)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "code-7" && fields["client_id"] == "client-1")
        #expect(fields["redirect_uri"] == "ch.goodvantage.Nevermore://oauth" && fields["code_verifier"] == "verifier-8")
    }

    @Test func grantFailuresSurfaceAsOAuthErrors() async throws {
        let session = StubURLProtocol.install { request in
            stubResponse(request, 400, #"{"error":"invalid_grant","error_description":"sensitive detail not for users"}"#)
        }
        do {
            _ = try await RavenClient.exchange(origin: URL(string: "https://site.test")!, clientID: "c", redirectURI: URL(string: "ch.goodvantage.Nevermore://oauth")!, code: "x", verifier: "v", session: session)
            Issue.record("expected throw")
        } catch let error as RavenError {
            #expect(error == .oauth("invalid_grant"))
            #expect(error.isPermanent)
            #expect(!error.localizedDescription.contains("sensitive detail"))
        }
    }

    @Test func downloadRefusesOtherOrigins() async throws {
        let hits = Mutex(0)
        let session = StubURLProtocol.install { request in
            hits.withLock { $0 += 1 }
            return stubResponse(request, 200, #""x""#)
        }
        do {
            _ = try await client(session, tokens: validTokens).download(URL(string: "https://other.test/private/files/x.png")!)
            Issue.record("expected throw")
        } catch let error as RavenError {
            #expect(error == .crossOrigin)
        }
        #expect(hits.withLock { $0 } == 0)
    }

    @Test func downloadFetchesSameOriginBytes() async throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        let session = StubURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!, payload)
        }
        let data = try await client(session, tokens: validTokens).download(URL(string: "https://site.test/private/files/x.png")!)
        #expect(data == payload)
    }

    @Test func redirectPolicyConfinesCredentialsToTheOrigin() async {
        let delegate = RavenClient.SameOriginRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        var original = URLRequest(url: URL(string: "https://site.test/api/method/x")!)
        original.setValue("Bearer access-1", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        defer { task.cancel() }
        let redirect = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/track"])!

        let refused = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                newRequest: URLRequest(url: URL(string: "https://evil.example/track")!)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(refused == nil)

        let allowed = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                newRequest: URLRequest(url: URL(string: "https://site.test/private/files/x.png")!)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(allowed?.url?.host == "site.test")
        #expect(allowed?.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test func redirectAnswerStillSurfacesAsAnError() async throws {
        let session = StubURLProtocol.install { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/2", headerFields: ["Location": "https://site.test/elsewhere"])!, Data())
        }
        do {
            _ = try await client(session, tokens: validTokens).rpc("raven.api.native.boot")
            Issue.record("expected throw")
        } catch let error as RavenError {
            #expect(error == .http(302, nil))
        }
    }

    @Test func resourceUsesDocumentVerbsAndEncodedPaths() async throws {
        let seen = Mutex<[URLRequest]>([])
        let session = StubURLProtocol.install { request in
            seen.withLock { $0.append(request) }
            return stubResponse(request, 200, #"{"data":{"name":"SCH-1","scheduled_time":"2026-11-08 10:00:00"}}"#)
        }
        let client = client(session, tokens: validTokens)
        let updated = try await client.resource("Raven Scheduled Message", name: "SCH-1", values: ["scheduled_time": .string("2026-11-08 10:00:00")])
        #expect(updated["name"] == .string("SCH-1"))
        _ = try await client.resource("Raven Scheduled Message", name: "SCH-1", values: nil, delete: true)
        let requests = seen.withLock { $0 }
        #expect(requests[0].httpMethod == "PUT")
        #expect(requests[0].url?.path(percentEncoded: true) == "/api/resource/Raven%20Scheduled%20Message/SCH-1")
        #expect(requests[1].httpMethod == "DELETE")
    }

    @Test func uploadSendsPrivateMultipartToUploadFile() async throws {
        let seen = Mutex<URLRequest?>(nil)
        let session = StubURLProtocol.install { request in
            seen.withLock { $0 = request }
            return stubResponse(request, 200, #"{"message":{"name":"FILE-1","file_url":"/private/files/note.txt","file_size":5}}"#)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await client(session, tokens: validTokens).upload(file: file)
        #expect(result["file_url"] == .string("/private/files/note.txt"))
        let request = try #require(seen.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/method/upload_file")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        let body = String(decoding: stubBody(request), as: UTF8.self)
        #expect(body.contains(#"name="is_private""#) && body.contains(#"name="file""#) && body.contains("hello"))
    }
}
