import Foundation

public protocol LinkPreviewLoading: Sendable {
    /// Never throws: a preview is a convenience. nil means "show nothing".
    func preview(for url: URL) async -> LinkPreview?
    /// Bytes of a preview's `imageURL`, or nil.
    func imageData(for url: URL) async -> Data?
}

public protocol LinkPreviewHostResolving: Sendable {
    /// Every address the host resolves to; empty when it does not resolve.
    func addresses(for host: String) async -> [LinkPreviewPolicy.Address]
}

/// `getaddrinfo`-based resolver (run it off the cooperative thread pool's
/// critical path; it blocks).
public struct SystemHostResolver: LinkPreviewHostResolving {
    public init() {}

    public func addresses(for host: String) async -> [LinkPreviewPolicy.Address] {
        await PreviewBlockingIO.run {
            Self.resolve(host)
        }
    }

    /// `getaddrinfo` blocks, so it runs off the cooperative executor.
    private static func resolve(_ host: String) -> [LinkPreviewPolicy.Address] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [LinkPreviewPolicy.Address] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            addresses.append(contentsOf: address(from: current.pointee))
            node = current.pointee.ai_next
        }
        return addresses
    }

    private static func address(from info: addrinfo) -> [LinkPreviewPolicy.Address] {
        guard let raw = info.ai_addr else { return [] }
        if info.ai_family == AF_INET {
            let bytes = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
            }
            guard bytes.count == 4 else { return [] }
            return [.v4(bytes[0], bytes[1], bytes[2], bytes[3])]
        }
        if info.ai_family == AF_INET6 {
            let bytes = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count == 16 else { return [] }
            return [.v6(bytes)]
        }
        return []
    }
}

/// `AnyClass` arrays are not `Sendable`. The box keeps the test-only
/// protocol classes out of the strict-concurrency checks; the loader only
/// reads them when building a session configuration.
private struct ProtocolClassBox: @unchecked Sendable {
    let classes: [AnyClass]
}

enum FetchKind: Sendable {
    case html
    case image

    var maximumBytes: Int {
        switch self {
        case .html: return LinkPreviewPolicy.maximumHTMLBytes
        case .image: return LinkPreviewPolicy.maximumImageBytes
        }
    }

    /// A page's `<head>` is enough for a preview; a partial image is
    /// not a picture.
    var acceptsPartialData: Bool {
        switch self {
        case .html: return true
        case .image: return false
        }
    }

    var stopsAtHeadEnd: Bool {
        switch self {
        case .html: return true
        case .image: return false
        }
    }

    var acceptHeader: String {
        switch self {
        case .html: return "text/html,application/xhtml+xml;q=0.9"
        case .image: return "image/png,image/jpeg,image/gif,image/webp,image/avif,image/heic"
        }
    }

    func accepts(_ response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        switch self {
        case .html: return LinkPreviewPolicy.acceptsHTML(contentType: contentType)
        case .image: return LinkPreviewPolicy.acceptsImage(contentType: contentType)
        }
    }
}

struct FetchResult: Sendable {
    let body: Data?
    let response: URLResponse?
    let redirectTarget: URL?
}

private struct FetchOutcome {
    let data: Data
    let response: HTTPURLResponse
    let finalURL: URL
}

/// Fetches and parses link previews without any UI.
///
/// All mutable state lives on the actor, so concurrent calls are safe and
/// calls for the same address share one fetch.
public actor LinkPreviewLoader: LinkPreviewLoading {
    /// The crawler names make sites answer with their preview tags, as
    /// they do for other link previewers. The app is not named: a site
    /// learns nothing about which chat client asked.
    private static let userAgent = "Mozilla/5.0 (Macintosh) link-preview facebookexternalhit/1.1 Twitterbot/1.0"
    private static let previewCacheLimit = 64
    private static let imageCacheLimit = 16
    /// A failure is remembered so typing does not hammer a broken site.
    private static let failureCacheDuration: TimeInterval = 300
    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    private let resolver: any LinkPreviewHostResolving
    private let protocolClasses: ProtocolClassBox?

    private struct PreviewEntry {
        let preview: LinkPreview?
        let date: Date
    }

    private enum PreviewLookup {
        case hit(LinkPreview?)
        case miss
    }

    private var previewCache: [String: PreviewEntry] = [:]
    private var previewLRU: [String] = []
    private var inFlight: [String: Task<LinkPreview?, Never>] = [:]
    private struct ImageEntry {
        let data: Data?
        let date: Date
    }

    private var imageCache: [String: ImageEntry] = [:]
    private var imageLRU: [String] = []

    public init() {
        self.resolver = SystemHostResolver()
        self.protocolClasses = nil
    }

    /// Only tests install an unpinned stub `URLProtocol`; the public
    /// initializer always uses the pinned production transport.
    init(resolver: any LinkPreviewHostResolving, protocolClasses: [AnyClass]? = nil) {
        self.resolver = resolver
        self.protocolClasses = protocolClasses.map { ProtocolClassBox(classes: $0) }
    }

    public func preview(for url: URL) async -> LinkPreview? {
        guard LinkPreviewPolicy.isEligible(url) else { return nil }
        let key = url.absoluteString
        switch lookupPreview(key) {
        case .hit(let preview):
            return preview
        case .miss:
            break
        }
        // Concurrent calls for the same address share one fetch.
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task { await self.fetchPreview(for: url) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        storePreview(result, forKey: key)
        return result
    }

    public func imageData(for url: URL) async -> Data? {
        guard LinkPreviewPolicy.isEligible(url) else { return nil }
        let key = url.absoluteString
        // A picture that failed is remembered like a page that failed:
        // every address typed on one site tends to name the same picture.
        if let cached = imageCache[key], cached.data != nil || Date().timeIntervalSince(cached.date) < Self.failureCacheDuration {
            touchImage(key)
            return cached.data
        }
        let data = await fetch(url, kind: .image)?.data
        storeImage(data, forKey: key)
        return data
    }

    // MARK: - Fetch pipeline

    private func fetchPreview(for url: URL) async -> LinkPreview? {
        guard let outcome = await fetch(url, kind: .html) else { return nil }
        return LinkPreviewParser.preview(html: outcome.data, charset: outcome.response.textEncodingName, requested: url, final: outcome.finalURL)
    }

    /// One request, redirects resolved by the caller so each hop can be
    /// re-checked.
    private func fetch(_ url: URL, kind: FetchKind) async -> FetchOutcome? {
        var current = url
        var redirects = 0
        while true {
            guard LinkPreviewPolicy.isEligible(current), let host = current.host else { return nil }
            let addresses = await resolver.addresses(for: host)
            guard !addresses.isEmpty, addresses.allSatisfy(LinkPreviewPolicy.isPublic) else { return nil }
            guard let result = await performRequest(current, addresses: addresses, kind: kind) else { return nil }
            guard let response = result.response as? HTTPURLResponse else { return nil }
            guard let body = result.body else { return nil }
            if (200...299).contains(response.statusCode) {
                guard kind.accepts(response) else { return nil }
                return FetchOutcome(data: body, response: response, finalURL: current)
            }
            guard Self.redirectStatuses.contains(response.statusCode) else { return nil }
            guard redirects < LinkPreviewPolicy.maximumRedirects else { return nil }
            // Every hop must pass the lexical check and the resolver
            // check before the next request leaves the app.
            guard let target = result.redirectTarget ?? locationTarget(response, from: current) else { return nil }
            guard LinkPreviewPolicy.isEligible(target) else { return nil }
            redirects += 1
            current = target
        }
    }

    private func locationTarget(_ response: HTTPURLResponse, from url: URL) -> URL? {
        guard let location = response.value(forHTTPHeaderField: "Location") else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    private func performRequest(_ url: URL, addresses: [LinkPreviewPolicy.Address], kind: FetchKind) async -> FetchResult? {
        if protocolClasses == nil {
            return await PreviewBlockingIO.run {
                PinnedPreviewRequest.perform(url, addresses: addresses, kind: kind, userAgent: Self.userAgent)
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = LinkPreviewPolicy.requestTimeout
        request.httpShouldHandleCookies = false
        request.setValue(kind.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        var session: URLSession?
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<FetchResult?, Never>) in
            let delegate = FetchSessionDelegate(kind: kind) { fetched in
                continuation.resume(returning: fetched)
            }
            let made = self.makeSession(delegate: delegate)
            session = made
            made.dataTask(with: request).resume()
        }
        session?.finishTasksAndInvalidate()
        return result
    }

    private func makeSession(delegate: FetchSessionDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // No cookie storage, credential storage or URL cache: a preview
        // must not carry the user's identity or reuse a cached answer.
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = LinkPreviewPolicy.requestTimeout
        configuration.timeoutIntervalForResource = LinkPreviewPolicy.transferTimeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses.classes
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Caches

    private func lookupPreview(_ key: String) -> PreviewLookup {
        guard let entry = previewCache[key] else { return .miss }
        if entry.preview == nil, Date().timeIntervalSince(entry.date) >= Self.failureCacheDuration {
            previewCache[key] = nil
            previewLRU.removeAll { $0 == key }
            return .miss
        }
        touchPreview(key)
        return .hit(entry.preview)
    }

    private func storePreview(_ preview: LinkPreview?, forKey key: String) {
        if let index = previewLRU.firstIndex(of: key) {
            previewLRU.remove(at: index)
        }
        previewLRU.append(key)
        previewCache[key] = PreviewEntry(preview: preview, date: Date())
        while previewLRU.count > Self.previewCacheLimit {
            let evicted = previewLRU.removeFirst()
            previewCache[evicted] = nil
        }
    }

    private func touchPreview(_ key: String) {
        guard let index = previewLRU.firstIndex(of: key) else { return }
        previewLRU.remove(at: index)
        previewLRU.append(key)
    }

    private func storeImage(_ data: Data?, forKey key: String) {
        if let index = imageLRU.firstIndex(of: key) {
            imageLRU.remove(at: index)
        }
        imageLRU.append(key)
        imageCache[key] = ImageEntry(data: data, date: Date())
        while imageLRU.count > Self.imageCacheLimit {
            let evicted = imageLRU.removeFirst()
            imageCache[evicted] = nil
        }
    }

    private func touchImage(_ key: String) {
        guard let index = imageLRU.firstIndex(of: key) else { return }
        imageLRU.remove(at: index)
        imageLRU.append(key)
    }
}

/// Delegate for one request.
///
/// It stops the transfer at the byte cap or at `</head>`, refuses to
/// follow redirects itself (the loader re-checks every hop), and cancels
/// every authentication challenge except server trust, so the fetcher
/// never presents a client credential.
private final class FetchSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let kind: FetchKind
    private let maximumBytes: Int
    private let completion: @Sendable (FetchResult) -> Void
    private let lock = NSLock()
    private var response: URLResponse?
    private var data = Data()
    private var redirectTarget: URL?
    private var didFinish = false
    private var didStop = false
    private var searchedBytes = 0
    private static let endHeadTag = "</head>"

    init(kind: FetchKind, completion: @escaping @Sendable (FetchResult) -> Void) {
        self.kind = kind
        self.maximumBytes = kind.maximumBytes
        self.completion = completion
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(wantsBody(of: response) ? .allow : .cancel)
    }

    /// A successful answer of the wrong type, or an image that announces
    /// more bytes than the cap, is dropped before its body is downloaded.
    /// Redirects and errors keep their short bodies; the loader reads
    /// only their status.
    private func wantsBody(of response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return true }
        guard kind.accepts(http) else { return false }
        return kind.acceptsPartialData || http.expectedContentLength <= Int64(maximumBytes)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
        lock.lock()
        data.append(newData)
        var shouldStop = false
        if data.count > maximumBytes {
            // A page keeps its first bytes; an image is discarded below.
            if kind.acceptsPartialData {
                data = Data(data.prefix(maximumBytes))
            }
            shouldStop = true
        }
        if kind.stopsAtHeadEnd, !shouldStop, endsHead() {
            shouldStop = true
        }
        if shouldStop && !didStop {
            didStop = true
            dataTask.cancel()
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirectTarget = request.url
        lock.unlock()
        // The loader follows redirects itself so every hop is checked.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Server trust uses the system policy; every other challenge
        // (HTTP auth, client certificates) is cancelled.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let response = response ?? task.response
        let redirect = redirectTarget
        let stopped = didStop
        let overLimit = data.count > maximumBytes
        var body = data
        if overLimit && kind.acceptsPartialData {
            body = Data(body.prefix(maximumBytes))
        }
        lock.unlock()

        // A transfer this delegate stopped on purpose still has a usable
        // prefix; any other failure has no body.
        guard stopped || error == nil else {
            completion(FetchResult(body: nil, response: response, redirectTarget: redirect))
            return
        }
        // A partial image is not a picture.
        if overLimit && !kind.acceptsPartialData {
            completion(FetchResult(body: nil, response: response, redirectTarget: redirect))
            return
        }
        completion(FetchResult(body: body, response: response, redirectTarget: redirect))
    }

    /// True once the page's `</head>` has been seen, case-insensitively.
    /// Lenient decoding keeps ASCII bytes intact, so this works for any
    /// ASCII-compatible charset. Only the bytes that arrived since the
    /// last look are searched (plus enough overlap for a tag split across
    /// two chunks), so a page delivered in tiny chunks costs no more than
    /// one delivered at once. Call with the lock held.
    private func endsHead() -> Bool {
        let start = max(0, searchedBytes - (Self.endHeadTag.utf8.count - 1))
        searchedBytes = data.count
        let text = String(decoding: data[(data.startIndex + start)...], as: UTF8.self)
        return text.range(of: Self.endHeadTag, options: .caseInsensitive) != nil
    }
}
