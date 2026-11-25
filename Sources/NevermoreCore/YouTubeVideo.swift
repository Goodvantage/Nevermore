import Foundation

/// Recognizes video links and constructs a fresh player URL from the video ID.
public struct YouTubeVideo: Equatable, Sendable {
    public let id: String

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.percentEncodedHost?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else { return nil }

        let path = parts.percentEncodedPath.components(separatedBy: "/")
        let id: String
        switch host {
        case "youtu.be":
            guard path.count == 2 else { return nil }
            id = path[1]
        case "youtube.com", "www.youtube.com", "m.youtube.com":
            if path == ["", "watch"] {
                let videos = parts.queryItems?.filter { $0.name == "v" }
                guard let videos, videos.count == 1, let video = videos[0].value else { return nil }
                id = video
            } else {
                guard path.count == 3, ["shorts", "live", "embed"].contains(path[1]) else { return nil }
                id = path[2]
            }
        default:
            return nil
        }
        guard id.wholeMatch(of: /[A-Za-z0-9_-]{11}/) != nil else { return nil }
        self.id = id
    }

    public var embedURL: URL {
        URL(string: "https://www.youtube.com/embed/\(id)?playsinline=1")!
    }
}
