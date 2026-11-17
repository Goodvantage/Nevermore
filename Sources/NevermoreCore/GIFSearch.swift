import Foundation

/// A GIF search service the picker can use. Tenor is not one: Google shut
/// its public API down on 30 June 2026.
public enum GIFProvider: String, Sendable, CaseIterable {
    case klipy, giphy

    public static let defaultsKey = "gifProvider"
    public static let standard = GIFProvider.klipy

    public init(storedValue: String?) {
        self = storedValue.flatMap(GIFProvider.init(rawValue:)) ?? .standard
    }

    public var name: String {
        switch self {
        case .klipy: return "KLIPY"
        case .giphy: return "GIPHY"
        }
    }

    /// Both services require this line wherever their results are shown.
    public var attribution: String { "Powered by \(name)" }

    /// Where a developer key is created.
    public var keyPage: URL {
        switch self {
        case .klipy: return URL(string: "https://partner.klipy.com")!
        case .giphy: return URL(string: "https://developers.giphy.com/dashboard/")!
        }
    }

    /// The API host. Search requests go nowhere else.
    var apiHost: String {
        switch self {
        case .klipy: return "api.klipy.com"
        case .giphy: return "api.giphy.com"
        }
    }
}

/// How strict the service's content filter is.
public enum GIFRating: String, Sendable, CaseIterable {
    case g, pg, pg13 = "pg-13", r

    public static let defaultsKey = "gifRating"
    /// A workplace default.
    public static let standard = GIFRating.pg

    public init(storedValue: String?) {
        self = storedValue.flatMap(GIFRating.init(rawValue:)) ?? .standard
    }

    public var title: String {
        switch self {
        case .g: return "G: suitable for everyone"
        case .pg: return "PG: mild"
        case .pg13: return "PG-13: moderate"
        case .r: return "R: unrestricted"
        }
    }

    /// KLIPY names its levels after how much it filters.
    var klipyFilter: String {
        switch self {
        case .g: return "high"
        case .pg: return "medium"
        case .pg13: return "low"
        case .r: return "off"
        }
    }
}

/// One file of a GIF at one size.
public struct GIFRendition: Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    /// Bytes, when the service says.
    public let bytes: Int?

    public init(url: URL, width: Int, height: Int, bytes: Int? = nil) {
        self.url = url; self.width = width; self.height = height; self.bytes = bytes
    }
}

/// A search result.
public struct GIFItem: Sendable, Equatable, Identifiable {
    public let id: String
    /// The service's title, used as the image's alternative text.
    public let title: String
    /// Small and light, for the picker grid.
    public let preview: GIFRendition
    /// What is sent: large enough to read in a conversation, small enough
    /// to send quickly.
    public let message: GIFRendition

    public init(id: String, title: String, preview: GIFRendition, message: GIFRendition) {
        self.id = id; self.title = title; self.preview = preview; self.message = message
    }
}

public struct GIFPage: Sendable, Equatable {
    public let items: [GIFItem]
    /// Pass back to get the following page; nil at the end.
    public let next: Int?

    public init(items: [GIFItem], next: Int?) { self.items = items; self.next = next }
}

public enum GIFSearchError: Error, Equatable, LocalizedError {
    case missingKey
    case rejectedKey
    case rateLimited
    case unavailable
    case malformed

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add a GIF service key in Settings to search for GIFs."
        case .rejectedKey: return "The GIF service did not accept the key in Settings."
        case .rateLimited: return "The GIF service is limiting searches. Try again in a few minutes."
        case .unavailable: return "The GIF service could not be reached. Try again."
        case .malformed: return "The GIF service sent results Nevermore cannot read."
        }
    }
}

/// Builds requests and reads answers for one service. Pure, so tests can
/// check both without a network.
public struct GIFSearchRequest: Sendable {
    public let provider: GIFProvider
    public let key: String
    public let rating: GIFRating
    /// Two-letter language of the searches, such as `de`.
    public let language: String
    /// Two-letter region, such as `CH`, when known.
    public let region: String?
    /// KLIPY asks for a stable, anonymous identifier per user. It is
    /// random and kept on this Mac; it is not the Raven account.
    public let clientID: String
    public static let pageSize = 24
    /// GIPHY serves no results past this offset.
    public static let maximumOffset = 4999
    /// The longest query sent.
    public static let maximumQueryLength = 100

    public init(provider: GIFProvider, key: String, rating: GIFRating, language: String, region: String?, clientID: String) {
        self.provider = provider; self.key = key; self.rating = rating; self.clientID = clientID
        let letters = { (value: String) in value.count == 2 && value.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) } }
        self.language = letters(language) ? language.lowercased() : "en"
        self.region = region.flatMap { letters($0) ? $0.uppercased() : nil }
    }

    /// A key is a short token of letters, digits, `-` and `_`. Anything
    /// else is refused before it reaches a URL.
    public static func isPlausibleKey(_ key: String) -> Bool {
        (8...128).contains(key.count) && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Trending GIFs for an empty query, else a search. `cursor` is a
    /// previous page's `next`.
    public func url(query: String, cursor: Int?) throws -> URL {
        guard Self.isPlausibleKey(key) else { throw GIFSearchError.missingKey }
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumQueryLength))
        var components = URLComponents()
        components.scheme = "https"
        components.host = provider.apiHost
        var items: [URLQueryItem]
        switch provider {
        case .giphy:
            components.path = trimmed.isEmpty ? "/v1/gifs/trending" : "/v1/gifs/search"
            items = [
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(max(0, cursor ?? 0))),
                URLQueryItem(name: "rating", value: rating.rawValue),
                URLQueryItem(name: "bundle", value: "messaging_non_clips"),
            ]
            if !trimmed.isEmpty {
                items.append(URLQueryItem(name: "q", value: trimmed))
                items.append(URLQueryItem(name: "lang", value: language))
            }
        case .klipy:
            components.path = "/api/v1/\(key)/gifs/" + (trimmed.isEmpty ? "trending" : "search")
            items = [
                URLQueryItem(name: "page", value: String(max(1, cursor ?? 1))),
                URLQueryItem(name: "per_page", value: String(Self.pageSize)),
                URLQueryItem(name: "customer_id", value: clientID),
                URLQueryItem(name: "content_filter", value: rating.klipyFilter),
                URLQueryItem(name: "format_filter", value: "gif"),
            ]
            if let region { items.append(URLQueryItem(name: "locale", value: region)) }
            if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        }
        components.queryItems = items
        guard let url = components.url else { throw GIFSearchError.malformed }
        return url
    }

    /// Reads one page. Results whose files are not on the service's media
    /// hosts, or are not GIFs, are left out.
    public func page(from data: Data, cursor: Int?) throws -> GIFPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GIFSearchError.malformed }
        switch provider {
        case .giphy: return try Self.giphyPage(root, offset: min(max(0, cursor ?? 0), Self.maximumOffset))
        case .klipy: return try Self.klipyPage(root, page: max(1, cursor ?? 1))
        }
    }

    static func giphyPage(_ root: [String: Any], offset: Int) throws -> GIFPage {
        guard let data = root["data"] as? [[String: Any]] else { throw GIFSearchError.malformed }
        let items = data.compactMap { object -> GIFItem? in
            guard let id = object["id"] as? String, let images = object["images"] as? [String: Any] else { return nil }
            func rendition(_ name: String) -> GIFRendition? {
                guard let image = images[name] as? [String: Any] else { return nil }
                return Self.rendition(image["url"], width: image["width"], height: image["height"], bytes: image["size"])
            }
            guard let preview = rendition("fixed_width_small") ?? rendition("fixed_width") ?? rendition("preview_gif"),
                  let message = rendition("fixed_width") ?? rendition("downsized") ?? rendition("original") else { return nil }
            let title = (object["alt_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (object["title"] as? String) ?? ""
            return GIFItem(id: id, title: Self.cleanTitle(title), preview: preview, message: message)
        }
        let pagination = root["pagination"] as? [String: Any]
        // Bounded, so a malformed count cannot overflow the next offset.
        let count = min(max(0, Self.int(pagination?["count"]) ?? data.count), Self.maximumOffset)
        let total = Self.int(pagination?["total_count"])
        let next = offset + count
        let hasMore = count > 0 && next <= maximumOffset && (total.map { next < $0 } ?? (count >= pageSize))
        return GIFPage(items: items, next: hasMore ? next : nil)
    }

    static func klipyPage(_ root: [String: Any], page: Int) throws -> GIFPage {
        guard let envelope = root["data"] as? [String: Any], let data = envelope["data"] as? [[String: Any]] else { throw GIFSearchError.malformed }
        let items = data.compactMap { object -> GIFItem? in
            // Advertisements are other kinds of entries; the picker shows GIFs only.
            if let type = object["type"] as? String, type != "gif" { return nil }
            guard let id = Self.string(object["id"]) ?? (object["slug"] as? String), let files = object["file"] as? [String: Any] else { return nil }
            func rendition(_ size: String) -> GIFRendition? {
                guard let sized = files[size] as? [String: Any], let gif = sized["gif"] as? [String: Any] else { return nil }
                return Self.rendition(gif["url"], width: gif["width"], height: gif["height"], bytes: gif["size"])
            }
            guard let preview = rendition("sm") ?? rendition("xs") ?? rendition("md"),
                  let message = rendition("md") ?? rendition("hd") ?? rendition("sm") else { return nil }
            return GIFItem(id: id, title: Self.cleanTitle((object["title"] as? String) ?? ""), preview: preview, message: message)
        }
        let hasNext = (envelope["has_next"] as? Bool) ?? false
        return GIFPage(items: items, next: hasNext ? page + 1 : nil)
    }

    /// Maps an error answer to what the reader can do about it. KLIPY
    /// answers an unknown key with 404 and a message naming the key.
    public func error(status: Int, body: Data) -> GIFSearchError {
        switch status {
        case 401, 403: return .rejectedKey
        case 429: return .rateLimited
        case 404 where provider == .klipy:
            let text = String(decoding: body.prefix(2048), as: UTF8.self).lowercased()
            return text.contains("key") ? .rejectedKey : .unavailable
        default: return .unavailable
        }
    }

    private static func rendition(_ url: Any?, width: Any?, height: Any?, bytes: Any?) -> GIFRendition? {
        guard let string = url as? String, let url = URL(string: string), GIFMediaPolicy.isServiceMedia(url),
              let width = int(width), let height = int(height), (1...4096).contains(width), (1...4096).contains(height) else { return nil }
        return GIFRendition(url: url, width: width, height: height, bytes: int(bytes))
    }

    /// GIPHY sends numbers as strings.
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    /// One line, bounded, without control characters.
    static func cleanTitle(_ title: String) -> String {
        let line = title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(line.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
    }
}

/// Searches one GIF service.
public protocol GIFSearching: Sendable {
    var provider: GIFProvider { get }
    /// Trending GIFs for an empty query. `cursor` is a previous page's `next`.
    func page(query: String, cursor: Int?) async throws -> GIFPage
}

/// Talks to the service's API host only: HTTPS, no cookies, no cache, no
/// credentials, redirects refused, answers capped. The request carries the
/// service key and the query; never anything from Raven.
public final class GIFSearchClient: GIFSearching {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    static let userAgent = "Nevermore (macOS)"
    public let request: GIFSearchRequest
    public var provider: GIFProvider { request.provider }
    private let session: URLSession

    public init(request: GIFSearchRequest) {
        self.request = request
        self.session = Self.makeSession(protocolClasses: nil)
    }

    /// Tests route requests through a stub `URLProtocol`.
    init(request: GIFSearchRequest, protocolClasses: [AnyClass]) {
        self.request = request
        self.session = Self.makeSession(protocolClasses: protocolClasses)
    }

    deinit { session.invalidateAndCancel() }

    private static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func page(query: String, cursor: Int?) async throws -> GIFPage {
        let url = try request.url(query: query, cursor: cursor)
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var data = Data(), response: URLResponse
        do {
            // Read as it arrives, so an oversized answer stops at the cap.
            let (bytes, head) = try await session.bytes(for: urlRequest)
            response = head
            guard head.expectedContentLength <= Int64(Self.maximumResponseBytes) else { bytes.task.cancel(); throw GIFSearchError.malformed }
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maximumResponseBytes { bytes.task.cancel(); throw GIFSearchError.malformed }
            }
        }
        catch let error as GIFSearchError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw GIFSearchError.unavailable }
        guard let http = response as? HTTPURLResponse, http.url?.host == url.host else { throw GIFSearchError.unavailable }
        guard (200...299).contains(http.statusCode) else { throw request.error(status: http.statusCode, body: data) }
        return try request.page(from: data, cursor: cursor)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
