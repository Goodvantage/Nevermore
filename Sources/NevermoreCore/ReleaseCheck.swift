import Foundation

/// An advisory download offer, never an instruction to replace the app.
public struct ReleaseOffer: Sendable, Equatable {
    public let version: ReleaseVersion
    public let downloadURL: URL
    public static let websiteURL = URL(string: "https://apps.goodvantage.cloud/#nevermore")!

    /// Validate the publisher's schema before exposing any browser action.
    /// Beta feeds may contain a stable release when it supersedes a beta.
    public static func decode(_ data: Data, running: ReleaseVersion) throws -> ReleaseOffer? {
        guard data.count <= ReleaseCheck.maximumBytes else { throw ReleaseCheckError.invalidManifest }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw ReleaseCheckError.invalidManifest }
        guard manifest.schema == 1, manifest.app == "nevermore",
              let version = ReleaseVersion(manifest.version),
              manifest.channel == (version.isPrerelease ? "beta" : "stable"),
              running.isPrerelease || !version.isPrerelease else { throw ReleaseCheckError.invalidManifest }
        guard let artifact = manifest.downloads["macos"] else { return nil }
        guard artifact.size > 0, artifact.size <= 2 * 1024 * 1024 * 1024,
              artifact.sha256.utf8.count == 64,
              artifact.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              !artifact.file.isEmpty, artifact.file.utf8.count <= 255,
              artifact.file.utf8.first.map({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) == true,
              artifact.file.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43, 126].contains($0) }),
              let url = URL(string: artifact.url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == "apps.goodvantage.cloud",
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path == "/nevermore/\(version)/\(artifact.file)" else { throw ReleaseCheckError.invalidManifest }
        guard version > running else { return nil }
        return ReleaseOffer(version: version, downloadURL: url)
    }

    private struct Manifest: Decodable {
        let schema: Int
        let app: String
        let channel: String
        let version: String
        let downloads: [String: Artifact]
    }
    private struct Artifact: Decodable {
        let url: String
        let file: String
        let size: Int64
        let sha256: String
    }
}

public enum ReleaseCheckError: Error, LocalizedError {
    case invalidManifest, unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "The update information is invalid. Try again later or open the download website."
        case .unavailable: "Could not check for updates. Check your connection and try again."
        }
    }
}

/// A separate, credential-free transport. Never reuse a Raven account session.
public struct ReleaseCheck: Sendable {
    public static let maximumBytes = 256 * 1024
    public static func manifestURL(for version: ReleaseVersion) -> URL {
        URL(string: "https://apps.goodvantage.cloud/nevermore/\(version.isPrerelease ? "beta" : "stable").json")!
    }

    public init() {}

    public func fetch(for version: ReleaseVersion) async throws -> ReleaseOffer? {
        try await fetch(for: version, configuration: .ephemeral)
    }

    // Configuration injection is internal and used by transport tests only.
    func fetch(for version: ReleaseVersion, configuration: URLSessionConfiguration) async throws -> ReleaseOffer? {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ReleaseTransportBoundary(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.manifestURL(for: version), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Nevermore/\(version) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ReleaseCheckError.unavailable }
            // A channel need not exist until its first release is published.
            if response.statusCode == 404 { return nil }
            guard response.statusCode == 200 else { throw ReleaseCheckError.unavailable }
            guard response.expectedContentLength <= Self.maximumBytes else { throw ReleaseCheckError.invalidManifest }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw ReleaseCheckError.invalidManifest }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try ReleaseOffer.decode(data, running: version)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ReleaseCheckError { throw error }
        catch { throw ReleaseCheckError.unavailable }
    }
}

// Internal so tests can exercise the redirect decision independently of
// URLProtocol's platform-specific redirect simulation.
final class ReleaseTransportBoundary: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The canonical channel URL is direct. Never follow a redirect to an
        // account server, local service, or another download provider.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
