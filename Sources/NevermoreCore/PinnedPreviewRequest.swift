import CPreviewTransport
import Foundation

/// System libcurl supplies HTTP framing, decompression and TLS validation.
/// Its DNS entry is pinned to the policy-checked addresses, and its socket
/// callback checks the actual endpoint again before a socket can be opened.
/// All callbacks and buffer mutation stay on one utility task's thread.
enum PinnedPreviewRequest {
    static func perform(_ url: URL, addresses: [LinkPreviewPolicy.Address], kind: FetchKind, userAgent: String,
                        connectionCheck: @escaping @Sendable (LinkPreviewPolicy.Address) -> Bool = { _ in true }) -> FetchResult? {
        guard let host = url.host, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              !host.isEmpty, host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !addresses.isEmpty, addresses.allSatisfy(LinkPreviewPolicy.isPublic) else { return nil }
        let numeric = addresses.compactMap(\.numericHost)
        guard numeric.count == addresses.count else { return nil }
        let entry = host + ":443:" + numeric.map { $0.contains(":") ? "[\($0)]" : $0 }.joined(separator: ",")
        let buffer = Buffer(url: url, kind: kind, addresses: addresses, connectionCheck: connectionCheck)
        let context = Unmanaged.passUnretained(buffer).toOpaque()
        let result = nm_preview_fetch(url.absoluteString, entry, userAgent, "Accept: " + kind.acceptHeader,
                                      Int(LinkPreviewPolicy.requestTimeout), Int(LinkPreviewPolicy.transferTimeout),
                                      { bytes, count, context in
            guard let bytes, let context else { return 0 }
            return Unmanaged<Buffer>.fromOpaque(context).takeUnretainedValue().receiveHeader(Data(bytes: bytes, count: count)) ? count : 0
        }, { bytes, count, context in
            guard let bytes, let context else { return 0 }
            return Unmanaged<Buffer>.fromOpaque(context).takeUnretainedValue().receiveBody(Data(bytes: bytes, count: count)) ? count : 0
        }, { address, context in
            guard let address, let context, let parsed = LinkPreviewPolicy.Address(numericHost: String(cString: address)) else { return 0 }
            let buffer = Unmanaged<Buffer>.fromOpaque(context).takeUnretainedValue()
            return buffer.addresses.contains(parsed) && LinkPreviewPolicy.isPublic(parsed) && buffer.connectionCheck(parsed) ? 1 : 0
        }, context)
        return buffer.result(succeeded: result == 0)
    }

    /// Bounded decoded bytes, shared by production callbacks and unit tests.
    final class Buffer {
        private static let maximumHeaderBytes = 64 * 1024
        private let url: URL
        private let kind: FetchKind
        fileprivate let addresses: [LinkPreviewPolicy.Address]
        fileprivate let connectionCheck: @Sendable (LinkPreviewPolicy.Address) -> Bool
        private var headerBytes = 0
        private var status: Int?
        private var headers: [String: String] = [:]
        private var response: HTTPURLResponse?
        private var data = Data()
        private var stopped = false
        private var invalid = false
        private var searchedBytes = 0

        init(url: URL, kind: FetchKind, addresses: [LinkPreviewPolicy.Address] = [],
             connectionCheck: @escaping @Sendable (LinkPreviewPolicy.Address) -> Bool = { _ in true }) {
            self.url = url
            self.kind = kind
            self.addresses = addresses
            self.connectionCheck = connectionCheck
        }

        func receiveHeader(_ bytes: Data) -> Bool {
            headerBytes += bytes.count
            guard headerBytes <= Self.maximumHeaderBytes else { invalid = true; return false }
            // Chunked response trailers cannot replace the final headers.
            if response != nil { return true }
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            if line.hasPrefix("HTTP/") {
                status = line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                headers = [:]
                return true
            }
            if line.isEmpty {
                guard let status else { invalid = true; return false }
                if (100...199).contains(status) { return true }
                response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
                guard let response else { invalid = true; return false }
                // Redirects need only their headers. Nothing follows them
                // until the loader has resolved and checked the next host.
                if !(200...299).contains(status) { stopped = true; return false }
                guard kind.accepts(response), kind.acceptsPartialData || response.expectedContentLength <= Int64(kind.maximumBytes) else {
                    invalid = true
                    return false
                }
                return true
            }
            guard let separator = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { invalid = true; return false }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            // Repeated cookies and other irrelevant fields are harmless,
            // but do not guess which duplicate framing/type/location wins.
            if ["content-length", "content-type", "location"].contains(name), headers[name] != nil {
                invalid = true
                return false
            }
            headers[name] = value
            return true
        }

        func receiveBody(_ bytes: Data) -> Bool {
            guard response != nil, !invalid, !stopped else { return false }
            let remaining = kind.maximumBytes - data.count
            data.append(bytes.prefix(remaining))
            if bytes.count > remaining {
                if kind.acceptsPartialData { stopped = true } else { invalid = true }
                return false
            }
            if kind.stopsAtHeadEnd {
                let start = max(0, searchedBytes - 6)
                searchedBytes = data.count
                if String(decoding: data[start...], as: UTF8.self).range(of: "</head>", options: .caseInsensitive) != nil {
                    stopped = true
                    return false
                }
            }
            return true
        }

        func result(succeeded: Bool) -> FetchResult? {
            guard !invalid, let response else { return nil }
            return FetchResult(body: succeeded || stopped ? data : nil, response: response, redirectTarget: nil)
        }
    }
}

extension LinkPreviewPolicy.Address {
    fileprivate var numericHost: String? {
        switch self {
        case .v4(let a, let b, let c, let d): return "\(a).\(b).\(c).\(d)"
        case .v6(let bytes):
            guard bytes.count == 16 else { return nil }
            return stride(from: 0, to: 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }.joined(separator: ":")
        }
    }

    fileprivate init?(numericHost: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, numericHost, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            self = .v4(bytes[0], bytes[1], bytes[2], bytes[3])
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, numericHost, &v6) == 1 else { return nil }
        self = .v6(withUnsafeBytes(of: v6) { Array($0) })
    }
}
