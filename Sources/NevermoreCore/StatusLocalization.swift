import Foundation
import RavenProtocol

/// Stable presentation keys, independent of persisted states and wire values.
/// German covers representative statuses only; missing entries fall back to English.
public enum StatusLocalization {
    public enum Key: String, CaseIterable, Sendable {
        case connecting = "connection.connecting"
        case reconnecting = "connection.reconnecting"
        case demo = "connection.demo"
        case cachedConnecting = "connection.cached_connecting"
        case maintenance = "connection.maintenance"
        case live = "connection.live"
        case httpOnly = "connection.http_only"
        case realtimeUnavailable = "connection.realtime_unavailable"
        case queued = "outbox.state.queued"
        case uploading = "outbox.state.uploading"
        case sending = "outbox.state.sending"
        case acknowledged = "outbox.state.acknowledged"
        case retryable = "outbox.state.retryable"
        case needsReview = "outbox.state.needs_review"
        case rejected = "outbox.state.rejected"
        case cancelled = "outbox.state.cancelled"
        case outboxArchived = "outbox.error.archived"
        case outboxAccessChanged = "outbox.error.access_changed"
        case outboxPermissionReview = "outbox.error.permission_review"
        case outboxOldReview = "outbox.error.old_review"
        case outboxAcknowledgementReview = "outbox.error.acknowledgement_review"
        case invalidSite = "error.protocol.invalid_site"
        case network = "error.protocol.transport"
        case oauth = "error.protocol.oauth"
        case unauthorized = "error.protocol.unauthorized"
        case httpDenied = "error.protocol.http_denied"
        case httpMissing = "error.protocol.http_missing"
        case httpBusy = "error.protocol.http_busy"
        case httpFailed = "error.protocol.http_failed"
        case httpRefused = "error.protocol.http_refused"
        case invalidResponse = "error.protocol.invalid_response"
        case resourceLimit = "error.protocol.resource_limit"
        case crossOrigin = "error.protocol.cross_origin"
        case keychain = "error.protocol.keychain"
        case storeDirectoryInUse = "error.store.directory_in_use"
        case storeLockFailed = "error.store.lock_failed"
        case draftNotFound = "error.store.draft_missing"
        case operationNotFound = "error.store.operation_missing"
        case immutableField = "error.store.immutable_field"
        case invalidAcknowledgement = "error.store.invalid_acknowledgement"
        case sourceNotReadable = "error.store.source_not_readable"
        case stagingBudget = "error.store.staging_budget"
        case richTooLarge = "error.rich.too_large"
        case richTooDeep = "error.rich.too_deep"
        case richUnsafeEdit = "error.rich.unsafe_edit"
        case accountAttention = "announcement.account_attention"
        case conversationAccessLost = "announcement.conversation_access_lost"
    }

    // Swift 6.1's generated accessor can miss Contents/Resources in an app
    // assembled outside Xcode. Do not evaluate its fallback until necessary:
    // sandboxed release apps cannot read the accessor's build-tree candidate.
    private static let resourceBundle = resolveResourceBundle(resourceDirectory: Bundle.main.resourceURL) { Bundle.module }

    static func resolveResourceBundle(resourceDirectory: URL?, fallback: () -> Bundle) -> Bundle {
        if let resourceDirectory,
           let packaged = Bundle(url: resourceDirectory.appendingPathComponent("Nevermore_NevermoreCore.bundle", isDirectory: true)) {
            return packaged
        }
        return fallback()
    }

    /// Resolved bundle location for packaged-app integrity checks.
    public static var resourceBundleURL: URL { resourceBundle.bundleURL }

    /// Explicit locales make formatting and fallback testable without changing
    /// UserDefaults or the process language. Normal callers use bundle preferences.
    public static func text(_ key: Key, locale: Locale? = nil, arguments: [CVarArg] = []) -> String {
        let language = locale.map { Bundle.preferredLocalizations(from: resourceBundle.localizations, forPreferences: [$0.identifier.replacingOccurrences(of: "_", with: "-")]).first ?? "en" }
            ?? resourceBundle.preferredLocalizations.first ?? "en"
        let localized = resourceBundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let english = resourceBundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let fallback = english?.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil) ?? key.rawValue
        let format = localized?.localizedString(forKey: key.rawValue, value: fallback, table: nil) ?? fallback
        return String(format: format, locale: locale ?? Locale.current, arguments: arguments)
    }

    /// Protocol types stay UI-free and cannot depend on this higher-level
    /// resource bundle. Localize their redacted copy at the app boundary.
    public static func errorDescription(_ error: Error, locale: Locale? = nil) -> String {
        guard let error = error as? RavenError else { return error.localizedDescription }
        func value(_ key: Key, _ arguments: CVarArg...) -> String { text(key, locale: locale, arguments: arguments) }
        switch error {
        case .invalidSite: return value(.invalidSite)
        case .transport: return value(.network)
        case .oauth(let code): return value(.oauth, code)
        case .unauthorized: return value(.unauthorized)
        case .invalidResponse: return value(.invalidResponse)
        case .resourceLimit: return value(.resourceLimit)
        case .crossOrigin: return value(.crossOrigin)
        case .keychain(let status): return value(.keychain, String(status))
        case .http(let status, let kind):
            let suffix = kind.map { " (\($0))" } ?? ""
            switch status {
            case 401, 403: return value(.httpDenied, status, suffix)
            case 404: return value(.httpMissing, suffix)
            case 409, 429: return value(.httpBusy, status, suffix)
            case 500...599: return value(.httpFailed, status, suffix)
            default: return value(.httpRefused, status, suffix)
            }
        }
    }
}

extension SendState {
    public func localizedLabel(locale: Locale? = nil) -> String {
        let key: StatusLocalization.Key
        switch self {
        case .queued: key = .queued
        case .uploading: key = .uploading
        case .sending: key = .sending
        case .acknowledged: key = .acknowledged
        case .retryable: key = .retryable
        case .needsReview: key = .needsReview
        case .rejected: key = .rejected
        case .cancelled: key = .cancelled
        }
        return StatusLocalization.text(key, locale: locale)
    }
}
