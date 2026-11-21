import Foundation
import Darwin

/// Authenticated transport for one Raven site. All requests use a per-client
/// isolated URLSession: no cookies, no shared cache, credentials never leave
/// the account origin (redirects to other origins are refused).
public actor RavenClient {
    public let origin: URL
    public let clientID: String
    public let accountID: UUID
    private(set) var tokens: OAuthTokens?
    private let session: URLSession
    /// False for a session injected by a contract test, which owns its own
    /// teardown. A client that built its own session must invalidate it:
    /// otherwise every re-login and account removal leaks a delegate, a
    /// thread and a configuration until the process ends.
    private let ownsSession: Bool
    /// The one outstanding refresh grant. Callers past the first await the
    /// shared task rather than posting a second refresh.
    private var pendingTokenPersistence = false
    private var invalidated = false
    private var inFlightRefresh: Task<OAuthTokens, Error>?
    /// Test seam: true once this client has torn down a session it owns.
    /// Observing ownership is the point; the tear-down itself is one call.
    private(set) var didInvalidateSession = false

    public init(origin: URL, tokens: OAuthTokens?, clientID: String, accountID: UUID) {
        self.init(origin: origin, tokens: tokens, clientID: clientID, accountID: accountID, session: nil, ownsSession: true)
    }

    /// Internal seam for contract tests with a stubbed URLProtocol. The test
    /// keeps the session and may share it between clients.
    init(origin: URL, tokens: OAuthTokens?, clientID: String, accountID: UUID, session: URLSession?) {
        self.init(origin: origin, tokens: tokens, clientID: clientID, accountID: accountID, session: session, ownsSession: false)
    }

    /// Internal seam for tests that observe session teardown.
    init(origin: URL, tokens: OAuthTokens?, clientID: String, accountID: UUID, session: URLSession?, ownsSession: Bool) {
        self.origin = origin
        self.tokens = tokens
        self.clientID = clientID
        self.accountID = accountID
        self.session = session ?? Self.makeSession()
        // Derive ownership from what happened, not only what the caller
        // declared: a nil session means the client created one and must
        // release it.
        self.ownsSession = ownsSession || session == nil
    }

    isolated deinit {
        if ownsSession { invalidateOwnedSession() }
    }

    private func invalidateOwnedSession() {
        // invalidate(), revoke() and deinit can all reach this; tearing down
        // once is enough.
        guard !didInvalidateSession else { return }
        session.invalidateAndCancel()
        didInvalidateSession = true
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(), delegateQueue: nil)
    }

    /// Credentials may only travel to this account's origin.
    final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let source = task.originalRequest?.url, let target = request.url, SiteOrigin.sameOrigin(source, target) else {
                completionHandler(nil)
                return
            }
            var request = request
            if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
               request.value(forHTTPHeaderField: "Authorization") == nil {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            completionHandler(request)
        }
    }

    // MARK: - RPC and document transport

    /// Calls `/api/method/<method>`. Reads are GET with query arguments;
    /// mutations are POST with a JSON body (the server enforces HTTP methods).
    /// Returns the unwrapped `message` envelope content.
    public func rpc(_ method: String, arguments: [String: JSONValue] = [:], mutation: Bool = false) async throws -> JSONValue {
        let (data, response) = try await perform { token in
            if mutation {
                var request = URLRequest(url: try self.endpoint(RavenEndpoints.methodPath(method)))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(JSONValue.object(arguments))
                return request
            }
            var query: [(String, String)] = []
            for (name, value) in arguments.sorted(by: { $0.key < $1.key }) {
                guard let encoded = value.ravenQueryValue else { continue }
                query.append((name, encoded))
            }
            return URLRequest(url: try self.endpoint(RavenEndpoints.methodPath(method), query: query))
        }
        try Self.check(data, response)
        return try Self.unwrapMessage(data)
    }

    /// Generic DocType REST: GET with `values == nil`, PUT to update,
    /// DELETE when `delete` is set.
    public func resource(_ doctype: String, name: String, values: [String: JSONValue]?, delete: Bool = false) async throws -> JSONValue {
        let (data, response) = try await perform { token in
            var request = URLRequest(url: try self.endpoint(RavenEndpoints.resourcePath(Self.encodeSegment(doctype), Self.encodeSegment(name))))
            if delete {
                request.httpMethod = "DELETE"
            } else if let values {
                request.httpMethod = "PUT"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(JSONValue.object(values))
            } else {
                request.httpMethod = "GET"
            }
            return request
        }
        try Self.check(data, response)
        let value = try Self.decode(data)
        if case .object(let object) = value, object.keys.contains("data") { return object["data"] ?? .null }
        return value
    }

    /// Multipart upload to `/api/method/upload_file`, private first, matching
    /// the composer contract. Returns the server File document verbatim; its
    /// `file_url`/`file_size` keys are what the send endpoint expects.
    public func upload(file: URL, filename suppliedName: String? = nil) async throws -> JSONValue {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        // A missing or unreadable size is not a budget refusal; it is still
        // reported as one until the protocol has a distinct local-file case.
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else { throw RavenError.resourceLimit(RavenError.maximumAttachmentBytes) }
        guard size <= RavenError.maximumAttachmentBytes else { throw RavenError.resourceLimit(RavenError.maximumAttachmentBytes) }
        let content = try Data(contentsOf: file)
        let name = suppliedName ?? file.lastPathComponent
        let filename = name.isEmpty ? "attachment" : name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "\"" || $0 == "\\" ? "_" : String($0) }.joined()
        let boundary = "Nevermore-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("is_private", "1")
        field("doctype", "Raven Message")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response) = try await perform { token in
            var request = URLRequest(url: try self.endpoint(RavenEndpoints.methodPath("upload_file")))
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        try Self.check(data, response)
        return try Self.unwrapMessage(data)
    }

    /// Authenticated binary fetch (private files). The target must be on this
    /// account's origin; other hosts are refused before any credential moves.
    public func download(_ url: URL, maximumBytes: Int = RavenError.maximumAttachmentBytes) async throws -> Data {
        guard SiteOrigin.sameOrigin(url, origin) else { throw RavenError.crossOrigin }
        _ = try RavenAttachmentURL.resolve(url.absoluteString, origin: origin)
        // Budgets outside 1...maximumAttachmentBytes are rejected as a limit
        // violation; a budget <= 0 lands here too, though nothing exceeded it.
        guard (1...RavenError.maximumAttachmentBytes).contains(maximumBytes) else { throw RavenError.resourceLimit(RavenError.maximumAttachmentBytes) }
        let (data, response) = try await perform(maximumBytes: maximumBytes) { token in
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            return request
        }
        try Self.check(data, response)
        return data
    }

    /// Stream a full attachment into a private file, retaining at most one
    /// 32 KiB chunk in memory. Partial/error/oversized downloads are removed;
    /// only a fully written and quarantined file can leave this method.
    public func download(_ url: URL, to directory: URL, maximumBytes: Int = RavenError.maximumAttachmentBytes) async throws -> DownloadedAttachment {
        guard SiteOrigin.sameOrigin(url, origin) else { throw RavenError.crossOrigin }
        _ = try RavenAttachmentURL.resolve(url.absoluteString, origin: origin)
        guard directory.isFileURL, (1...RavenError.maximumAttachmentBytes).contains(maximumBytes) else { throw RavenError.resourceLimit(RavenError.maximumAttachmentBytes) }
        let lease = try AttachmentDownloadLease(maximumBytes: maximumBytes)
        let fm = FileManager.default
        let accountDirectory = DownloadedAttachment.cacheDirectory(accountID: accountID, in: directory)
        let privateDirectory = accountDirectory.appendingPathComponent("NevermoreDownload-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: accountDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard mkdir(privateDirectory.path, 0o700) == 0 else { throw AttachmentDownloadError.storage }
        } catch { throw AttachmentDownloadError.storage }
        var transferred = false
        defer { if !transferred { try? fm.removeItem(at: privateDirectory) } }
        var retried = false
        while true {
            try Task.checkCancellation()
            guard !invalidated else { throw RavenError.unauthorized }
            let token = try await accessToken()
            var request = URLRequest(url: url); request.timeoutInterval = 300
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let stream: (URLSession.AsyncBytes, URLResponse)
            do { stream = try await session.bytes(for: request) }
            catch let error as URLError { if error.code == .cancelled { throw CancellationError() }; throw RavenError.transport }
            catch { if error is CancellationError { throw error }; throw RavenError.transport }
            let (bytes, rawResponse) = stream
            defer { bytes.task.cancel() }
            guard !invalidated else { throw RavenError.unauthorized }
            guard let response = rawResponse as? HTTPURLResponse else { throw RavenError.invalidResponse }
            guard response.url.map({ SiteOrigin.sameOrigin($0, origin) }) == true else { throw RavenError.crossOrigin }
            if response.statusCode == 401, token != nil, !retried {
                retried = true; bytes.task.cancel()
                if tokens?.accessToken == token { _ = try await accessToken(forceRefresh: true) }
                continue
            }
            guard response.statusCode == 200 else {
                var errorBody = Data()
                do { for try await byte in bytes { if errorBody.count >= 64 * 1024 { break }; errorBody.append(byte) } }
                catch let error as URLError { if error.code == .cancelled { throw CancellationError() }; throw RavenError.transport }
                try Self.check(errorBody, response)
                // A partial/range response is not a complete file download.
                throw RavenError.invalidResponse
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw RavenError.resourceLimit(maximumBytes) }
            let partial = privateDirectory.appendingPathComponent(".payload.part")
            let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw AttachmentDownloadError.storage }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var chunk = Data(); chunk.reserveCapacity(32 * 1024)
            var count = 0
            do {
                for try await byte in bytes {
                    guard count < maximumBytes else { throw RavenError.resourceLimit(maximumBytes) }
                    chunk.append(byte); count += 1
                    if chunk.count == 32 * 1024 {
                        try Task.checkCancellation(); guard !invalidated else { throw RavenError.unauthorized }
                        try file.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation(); guard !invalidated else { throw RavenError.unauthorized }
                if !chunk.isEmpty { try file.write(contentsOf: chunk) }
                try file.synchronize(); try file.close()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw RavenError.transport
            } catch {
                if error is RavenError || error is CancellationError { throw error }
                throw AttachmentDownloadError.storage
            }
            // Match the complete representation delivered by URLSession. It
            // normalizes decoded responses and preserves named gzip archives.
            if response.expectedContentLength >= 0, Int64(count) != response.expectedContentLength { throw RavenError.invalidResponse }
            let name = DownloadedAttachment.safeFilename(response.suggestedFilename ?? url.lastPathComponent)
            let complete = privateDirectory.appendingPathComponent(name)
            try DownloadedAttachment.quarantine(partial, origin: origin)
            do { try fm.moveItem(at: partial, to: complete) } catch { throw AttachmentDownloadError.storage }
            transferred = true
            return DownloadedAttachment(url: complete, directory: privateDirectory, contentType: response.mimeType, byteCount: count, origin: origin, lease: lease)
        }
    }

    // MARK: - OAuth grants

    /// Authorization-code + PKCE exchange at the token endpoint. Token
    /// endpoints return top-level OAuth fields, never a `message` envelope.
    public static func exchange(origin: URL, clientID: String, redirectURI: URL, code: String, verifier: String) async throws -> OAuthTokens {
        try await exchange(origin: origin, clientID: clientID, redirectURI: redirectURI, code: code, verifier: verifier, session: makeSession())
    }

    /// Internal seam for contract tests with a stubbed URLProtocol.
    static func exchange(origin: URL, clientID: String, redirectURI: URL, code: String, verifier: String, session: URLSession) async throws -> OAuthTokens {
        try await tokenGrant(origin: origin, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("code_verifier", verifier),
        ], priorRefresh: nil, session: session)
    }

    /// Stops local credential use before replacing or removing an account session.
    public func invalidate() {
        invalidated = true; inFlightRefresh?.cancel(); inFlightRefresh = nil
        pendingTokenPersistence = false; tokens = nil
        if ownsSession { invalidateOwnedSession() }
    }

    /// Best-effort refresh-token revocation on sign-out. Never throws; the
    /// local account is discarded regardless of the server's answer.
    public func revoke() async {
        let refreshToken = tokens?.refreshToken
        invalidated = true; inFlightRefresh?.cancel(); inFlightRefresh = nil; pendingTokenPersistence = false
        tokens = nil
        if let refreshToken, !refreshToken.isEmpty {
            var request = URLRequest(url: (try? endpoint(RavenEndpoints.revokePath)) ?? origin)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formBody([("token", refreshToken), ("token_type_hint", "refresh_token")]).utf8)
            _ = try? await session.data(for: request)
        }
        if ownsSession { invalidateOwnedSession() }
    }

    // MARK: - Internals

    /// Runs one authorized request. A 401 answer forces a single shared
    /// refresh and one retry; a second 401 is returned for mapping.
    private func perform(maximumBytes: Int = 8 * 1024 * 1024, _ build: (String?) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !invalidated else { throw RavenError.unauthorized }
        var didRetryUnauthorized = false
        while true {
            let token = try await accessToken()
            var request = try build(token)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await load(request, maximumBytes: maximumBytes)
            guard !invalidated else { throw RavenError.unauthorized }
            if response.statusCode == 401, token != nil, !didRetryUnauthorized {
                didRetryUnauthorized = true
                _ = try await accessToken(forceRefresh: true)
                continue
            }
            return (data, response)
        }
    }

    private func load(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            if response.expectedContentLength > Int64(maximumBytes) { throw RavenError.resourceLimit(maximumBytes) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw RavenError.resourceLimit(maximumBytes) }
                data.append(byte)
            }
            result = (data, response)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw RavenError.transport
        } catch {
            if error is CancellationError || error is RavenError { throw error }
            throw RavenError.transport
        }
        guard let response = result.1 as? HTTPURLResponse else { throw RavenError.invalidResponse }
        return (result.0, response)
    }

    /// Current access token, or nil for unauthenticated guest calls.
    private func accessToken(forceRefresh: Bool = false) async throws -> String? {
        guard let current = tokens else { return nil }
        if pendingTokenPersistence { try KeychainTokenStore.save(current, accountID: accountID); pendingTokenPersistence = false }
        guard forceRefresh || current.needsRefresh() else { return current.accessToken }
        return try await refreshTokens().accessToken
    }

    /// Single-flight refresh: the first caller starts the grant; concurrent
    /// callers await the same task. Fresh tokens are persisted to the
    /// account's Keychain item. Permanent grant failures drop credentials so
    /// the next call requires sign-in; network failures keep them.
    private func refreshTokens() async throws -> OAuthTokens {
        if let inFlightRefresh { return try await inFlightRefresh.value }
        guard let current = tokens, !current.refreshToken.isEmpty else { throw RavenError.unauthorized }
        let task = Task.detached { [session, origin, clientID, refreshToken = current.refreshToken] in
            try await Self.tokenGrant(
                origin: origin,
                fields: [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)],
                priorRefresh: refreshToken,
                session: session
            )
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        do {
            let fresh = try await task.value
            guard !invalidated, !Task.isCancelled else { throw CancellationError() }
            tokens = fresh
            pendingTokenPersistence = true
            try KeychainTokenStore.save(fresh, accountID: accountID)
            pendingTokenPersistence = false
            return fresh
        } catch {
            if case .oauth(let code) = error as? RavenError, ["invalid_grant", "invalid_client", "unauthorized_client", "access_denied"].contains(code) {
                tokens = nil
                try? KeychainTokenStore.delete(accountID: accountID)
                throw RavenError.unauthorized
            }
            throw error
        }
    }

    /// Form-encoded POST to the token endpoint for authorization_code and
    /// refresh_token grants.
    private static func tokenGrant(origin: URL, fields: [(String, String)], priorRefresh: String?, session: URLSession) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + RavenEndpoints.tokenPath)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formBody(fields).utf8)
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw RavenError.transport
        } catch {
            if error is CancellationError { throw error }
            throw RavenError.transport
        }
        guard let response = result.1 as? HTTPURLResponse else { throw RavenError.invalidResponse }
        let object = try? decode(result.0)
        if let code = object?["error"].string { throw RavenError.oauth(RavenError.sanitizedOAuthCode(code)) }
        guard (200..<300).contains(response.statusCode) else { throw Self.errorStatus(result.0, response) }
        guard let object else { throw RavenError.invalidResponse }
        guard let access = object["access_token"].string, !access.isEmpty else { throw RavenError.invalidResponse }
        guard let refresh = object["refresh_token"].string ?? priorRefresh, !refresh.isEmpty else { throw RavenError.oauth("missing_refresh_token") }
        var lifetime: TimeInterval = 3600
        if case .number(let seconds) = object["expires_in"] { lifetime = seconds }
        else if let text = object["expires_in"].string, let seconds = Double(text) { lifetime = seconds }
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(lifetime))
    }

    // MARK: - Response handling

    static func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw errorStatus(data, response) }
    }

    /// Maps a Frappe JSON error body to a structured error. `exc_type` is a
    /// class name; `_server_messages`/`exception` may hold tracebacks and are
    /// deliberately never surfaced.
    static func errorStatus(_ data: Data, _ response: HTTPURLResponse) -> RavenError {
        var kind: String?
        if let value = try? decode(data) {
            kind = RavenError.sanitizedKind(value["exc_type"].string)
            if kind == nil, let first = value["errors"].array.first { kind = RavenError.sanitizedKind(first["type"].string) }
        }
        return .http(response.statusCode, kind)
    }

    static func decode(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw RavenError.invalidResponse }
    }

    /// Returns the `message` envelope content; bodies without the envelope are
    /// returned whole so callers can apply their own contract checks.
    static func unwrapMessage(_ data: Data) throws -> JSONValue {
        let value = try decode(data)
        if case .object(let object) = value, object.keys.contains("message") { return object["message"] ?? .null }
        return value
    }

    // MARK: - URL building

    func endpoint(_ path: String, query: [(String, String)] = []) throws -> URL {
        var text = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        if !query.isEmpty {
            text += "?" + query.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: text) else { throw RavenError.invalidResponse }
        return url
    }

    /// RFC 3986 unreserved: the encoding Frappe's `quote_via=quote` produces.
    static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encodeSegment(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func formBody(_ fields: [(String, String)]) -> String {
        fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
    }
}

extension JSONValue {
    /// GET argument encoding: plain strings stay literal, everything else is
    /// JSON text (the same serialization web clients send). `.null` args are
    /// dropped rather than sent as the literal "null".
    var ravenQueryValue: String? {
        switch self {
        case .null: return nil
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            return number.truncatingRemainder(dividingBy: 1) == 0 && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
