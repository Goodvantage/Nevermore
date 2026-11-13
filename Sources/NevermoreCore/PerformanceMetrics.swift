import Foundation

public enum PerformanceMetrics {
    public struct Summary: Codable, Sendable {
        public let count: Int
        public let minimum: Double
        public let p50: Double
        public let p95: Double
        public let maximum: Double
    }
    /// Nearest-rank percentiles. Reject invalid samples instead of masking them.
    public static func summarize(_ samples: [Double]) -> Summary? {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        return Summary(count: sorted.count, minimum: sorted[0], p50: percentile(0.5), p95: percentile(0.95), maximum: sorted[sorted.count - 1])
    }
    public struct FeedbackSample: Sendable {
        public let clickToFeedbackMS: Double
        public let actionToFeedbackMS: Double
        public let preActionMS: Double
    }
    /// Split synthetic click overhead from actual target-action delivery. All
    /// timestamps use the same monotonic clock; never subtract a guessed delay.
    public static func feedbackSample(clickStarted: Double, actionDelivered: Double, observed: Double) -> FeedbackSample? {
        guard [clickStarted, actionDelivered, observed].allSatisfy(\.isFinite),
              clickStarted <= actionDelivered, actionDelivered <= observed else { return nil }
        return FeedbackSample(clickToFeedbackMS: (observed - clickStarted) * 1000,
                              actionToFeedbackMS: (observed - actionDelivered) * 1000,
                              preActionMS: (actionDelivered - clickStarted) * 1000)
    }
    public struct Options: Equatable, Sendable {
        public let idleSeconds: Int
        public let iterations: Int
        public let fixtureID: UUID
        public let cachedLaunchOnly: Bool
        public let reuseFixture: Bool
        public let loopbackOrigin: URL?
        public init(arguments: [String]) throws {
            guard arguments.contains("--demo"), arguments.contains("--performance-check"), !arguments.contains("--performance-cleanup"), !arguments.contains("--performance-seed") else { throw OptionsError.invalid }
            func integer(_ flag: String, default fallback: Int) throws -> Int {
                let positions = arguments.indices.filter { arguments[$0] == flag }
                guard positions.count <= 1 else { throw OptionsError.invalid }
                guard let index = positions.first else { return fallback }
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else { throw OptionsError.invalid }
                return value
            }
            cachedLaunchOnly = arguments.contains("--performance-cached-launch")
            reuseFixture = cachedLaunchOnly || arguments.contains("--performance-reuse-fixture")
            let originFlags = arguments.indices.filter { arguments[$0] == "--performance-loopback-origin" }
            guard originFlags.count <= 1 else { throw OptionsError.invalid }
            if let index = originFlags.first {
                guard index + 1 < arguments.count else { throw OptionsError.invalid }
                loopbackOrigin = try PerformanceMetrics.loopbackOrigin(arguments[index + 1])
            } else { loopbackOrigin = nil }
            guard !cachedLaunchOnly || loopbackOrigin == nil else { throw OptionsError.invalid }
            if reuseFixture { _ = try PerformanceMetrics.identifier(arguments: arguments, flag: "--performance-fixture-id", required: true) }
            fixtureID = try PerformanceMetrics.identifier(arguments: arguments, flag: "--performance-fixture-id", required: false) ?? UUID()
            idleSeconds = try integer("--performance-idle-seconds", default: 5)
            iterations = try integer("--performance-iterations", default: 20)
            guard (0...600).contains(idleSeconds), [10, 20].contains(iterations) else { throw OptionsError.invalid }
        }
    }
    private static func identifier(arguments: [String], flag: String, required: Bool) throws -> UUID? {
        let positions = arguments.indices.filter { arguments[$0] == flag }
        guard positions.count <= 1 else { throw OptionsError.invalid }
        guard let index = positions.first else {
            if required { throw OptionsError.invalid }
            return nil
        }
        guard index + 1 < arguments.count, let id = UUID(uuidString: arguments[index + 1]),
              id.uuidString.caseInsensitiveCompare(arguments[index + 1]) == .orderedSame else { throw OptionsError.invalid }
        return id
    }
    public static func cleanupID(arguments: [String]) throws -> UUID {
        guard arguments.contains("--demo"), !arguments.contains("--performance-check"),
              !arguments.contains("--performance-fixture-id"), !arguments.contains("--performance-seed"),
              let id = try identifier(arguments: arguments, flag: "--performance-cleanup", required: true) else { throw OptionsError.invalid }
        return id
    }
    public static func seedID(arguments: [String]) throws -> UUID {
        guard arguments.contains("--demo"), !arguments.contains("--performance-check"),
              !arguments.contains("--performance-cleanup"), !arguments.contains("--performance-fixture-id"),
              let id = try identifier(arguments: arguments, flag: "--performance-seed", required: true) else { throw OptionsError.invalid }
        return id
    }
    /// Only explicit loopback origins with a nonprivileged port. Validate before
    /// constructing a session or touching its store/Keychain/download directory.
    public static func loopbackOrigin(_ raw: String) throws -> URL {
        guard let parts = URLComponents(string: raw), parts.scheme == "http",
              let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              let port = parts.port, (1024...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else { throw OptionsError.invalid }
        return url
    }
    public static func fixtureDirectoryName(for id: UUID) -> String { "NevermorePerformance-\(id.uuidString)" }
    public enum OptionsError: Error { case invalid }
}
