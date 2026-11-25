import Foundation

/// Protocol errors with redacted, localized descriptions.
/// Server tracebacks, response bodies, request URLs with arguments, and token
/// material never reach the user-facing text. Only HTTP status codes, Frappe
/// exception class names, and OAuth protocol constants may be shown.
public enum RavenError: Error, Sendable, Equatable {
    /// The entered site address cannot be normalized into an acceptable origin.
    case invalidSite
    /// A local failure prevented the request from completing (offline, DNS, TLS,
    /// timeout, cancelled). No detail is retained beyond "the network failed".
    case transport
    /// The OAuth callback or grant failed. The payload is an OAuth error token
    /// such as `invalid_grant`, never the free-text `error_description`.
    case oauth(String)
    /// Credentials were rejected and cannot be refreshed; a fresh browser
    /// sign-in is required.
    case unauthorized
    /// The site answered with an HTTP failure. `kind` is the Frappe exception
    /// class name (`exc_type`) when the server supplied a safe one.
    case http(Int, String?)
    /// The response did not match the documented envelope or payload contract.
    case invalidResponse
    /// A download or response body exceeded the caller's byte budget. The
    /// associated value is the limit that applied, not always 64 MB.
    case resourceLimit(Int)
    /// The request was refused because it would send this account's
    /// credentials to a different origin.
    case crossOrigin
    /// Secure storage returned an OSStatus.
    case keychain(Int32)

    /// True when the site authoritatively denied access: HTTP 401/403 or a
    /// Frappe permission/authentication exception. Cached private content
    /// should be treated as possibly revoked.
    public var isPermissionDenied: Bool {
        switch self {
        case .unauthorized: return true
        case .http(let status, let kind):
            if status == 401 || status == 403 { return true }
            return ["PermissionError", "AuthenticationError"].contains(kind ?? "")
        default: return false
        }
    }

    /// A permanent client failure can occur after the server accepted a POST,
    /// such as rejecting an oversized acknowledgement or invalidating the
    /// session before it consumes the response. Only an invalid request site
    /// or an explicit, definitive HTTP refusal rules out acceptance here.
    public var definitivelyRefusedMutation: Bool {
        switch self {
        case .invalidSite: true
        case .http: isPermanent
        default: false
        }
    }

    /// True when retrying the identical request cannot succeed: client errors,
    /// credential failures and contract violations. False for transport
    /// failures and server-side 5xx/429 responses that may clear on retry.
    public var isPermanent: Bool {
        switch self {
        case .invalidSite, .unauthorized, .resourceLimit, .crossOrigin: return true
        // RFC 6749 OAuth codes describing a server-side condition are
        // transient: the grant may succeed on the next attempt. `server_error`
        // is the token endpoint's 5xx equivalent.
        case .oauth(let code): return !["temporarily_unavailable", "server_error"].contains(code)
        case .transport, .invalidResponse, .keychain: return false
        case .http(let status, _):
            switch status {
            case 408, 409, 425, 429: return false
            case 400..<500: return true
            default: return false
            }
        }
    }
}

public extension RavenError {
    /// Hard byte ceiling enforced for attachment uploads and downloads.
    static let maximumAttachmentBytes = 64 * 1024 * 1024
}

extension RavenError {
    /// The enforced byte budget in the same units the reader thinks in, so a
    /// 512-byte preview budget and a 64 MB attachment budget each report the
    /// limit that actually applied. `locale` keeps the number in the same
    /// language as the surrounding sentence.
    public static func formattedResourceLimit(_ bytes: Int, locale: Locale? = nil) -> String {
        let style = ByteCountFormatStyle(style: .file, locale: locale ?? Locale.current)
        return max(0, bytes).formatted(style)
    }
}

extension RavenError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSite:
            return "Enter the site’s origin only, for example https://chat.example.com. HTTPS is required outside local development."
        case .transport:
            return "The site could not be reached. Check your network connection and the site address."
        case .oauth(let code):
            return "The site did not complete authorization (\(code)). Check the dedicated OAuth client registration and try signing in again."
        case .unauthorized:
            return "This account’s credentials are no longer accepted. Sign in again to reconnect."
        case .http(let status, let kind):
            let suffix = kind.map { " (\($0))" } ?? ""
            switch status {
            case 401, 403:
                return "The site denied this request (HTTP \(status)\(suffix)). Your permissions may have changed or your sign-in may have expired."
            case 404:
                return "The site could not find the requested item (HTTP 404\(suffix)). It may have been deleted."
            case 409, 429:
                return "The site is busy right now (HTTP \(status)\(suffix)). Try again in a moment."
            case 500...599:
                return "The site failed to answer (HTTP \(status)\(suffix)). It may be restarting or overloaded."
            default:
                return "The site refused the request (HTTP \(status)\(suffix))."
            }
        case .invalidResponse:
            return "The site returned a response Nevermore could not understand."
        case .resourceLimit(let bytes):
            return "This file or response exceeds Nevermore’s safe size limit (\(Self.formattedResourceLimit(bytes)))."
        case .crossOrigin:
            return "This request points at a different site. Nevermore only sends account credentials to the account’s own site."
        case .keychain(let status):
            return "Secure credential storage failed (Keychain error \(status))."
        }
    }
}

extension RavenError {
    /// Accepts only an exception-class token (`exc_type`), never message text.
    static func sanitizedKind(_ raw: String?) -> String? {
        guard let raw, raw.count <= 80,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }),
              raw.first?.isLetter == true else { return nil }
        return raw
    }

    /// Accepts only an OAuth error token, never `error_description` prose.
    static func sanitizedOAuthCode(_ raw: String?) -> String {
        guard let raw, raw.count <= 80,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) else { return "authorization_failed" }
        return raw
    }
}
