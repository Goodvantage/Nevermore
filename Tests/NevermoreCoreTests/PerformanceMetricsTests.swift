import Foundation
import Testing
@testable import NevermoreCore

struct PerformanceMetricsTests {
    @Test func nearestRankAndInvalidSamples() throws {
        let summary = try #require(PerformanceMetrics.summarize(Array(1...20).reversed().map(Double.init)))
        #expect(summary.count == 20 && summary.p50 == 10 && summary.p95 == 19 && summary.maximum == 20)
        #expect(PerformanceMetrics.summarize([]) == nil)
        #expect(PerformanceMetrics.summarize([.infinity]) == nil)
        #expect(PerformanceMetrics.summarize([-1]) == nil)
    }
    @Test func feedbackTimingSeparatesMeasuredPreActionOverhead() throws {
        let sample = try #require(PerformanceMetrics.feedbackSample(clickStarted: 10, actionDelivered: 10.1, observed: 10.125))
        #expect(abs(sample.clickToFeedbackMS - 125) < 0.000001)
        #expect(abs(sample.actionToFeedbackMS - 25) < 0.000001)
        #expect(abs(sample.preActionMS - 100) < 0.000001)
        #expect(abs(sample.clickToFeedbackMS - sample.actionToFeedbackMS - sample.preActionMS) < 0.000001)
        #expect(PerformanceMetrics.feedbackSample(clickStarted: 10, actionDelivered: 9, observed: 11) == nil)
        #expect(PerformanceMetrics.feedbackSample(clickStarted: 10, actionDelivered: 11, observed: 10) == nil)
        #expect(PerformanceMetrics.feedbackSample(clickStarted: 10, actionDelivered: .nan, observed: 11) == nil)
    }
    @Test func cleanupAcceptsOnlyExplicitDemoCanonicalNonce() throws {
        let nonce = "00000000-0000-0000-0000-000000000123"
        let id = try PerformanceMetrics.cleanupID(arguments: ["--demo", "--performance-cleanup", nonce])
        #expect(PerformanceMetrics.fixtureDirectoryName(for: id) == "NevermorePerformance-" + nonce)
        #expect(try PerformanceMetrics.Options(arguments: ["--demo", "--performance-check", "--performance-fixture-id", nonce]).fixtureID == id)
        for invalid in [["--performance-cleanup", nonce], ["--demo", "--performance-cleanup", "/tmp/" + nonce], ["--demo", "--performance-cleanup"], ["--demo", "--performance-cleanup", nonce, "--performance-check"], ["--demo", "--performance-cleanup", nonce, "--performance-cleanup", nonce]] {
            #expect(throws: PerformanceMetrics.OptionsError.self) { try PerformanceMetrics.cleanupID(arguments: invalid) }
        }
        for invalid in ["../" + nonce, "not-a-uuid", "{" + nonce + "}"] {
            #expect(throws: PerformanceMetrics.OptionsError.self) { try PerformanceMetrics.Options(arguments: ["--demo", "--performance-check", "--performance-fixture-id", invalid]) }
        }
    }
    @Test func persistedLaunchAndLoopbackArgumentsAreBounded() throws {
        let nonce = "00000000-0000-0000-0000-000000000123"
        #expect(try PerformanceMetrics.seedID(arguments: ["--demo", "--performance-seed", nonce]).uuidString == nonce)
        let launch = try PerformanceMetrics.Options(arguments: ["--demo", "--performance-check", "--performance-fixture-id", nonce, "--performance-cached-launch"])
        #expect(launch.cachedLaunchOnly && launch.reuseFixture)
        for origin in ["http://127.0.0.1:12345", "http://localhost:12345", "http://[::1]:12345"] {
            #expect(try PerformanceMetrics.loopbackOrigin(origin).port == 12345)
        }
        for origin in ["https://example.com:12345", "http://example.com:12345", "http://127.0.0.2:12345", "http://127.0.0.1:80", "http://user@127.0.0.1:12345", "http://127.0.0.1:12345/path", "http://127.0.0.1:12345?token=x", "http://127.0.0.1:12345#fragment"] {
            #expect(throws: PerformanceMetrics.OptionsError.self) { try PerformanceMetrics.loopbackOrigin(origin) }
        }
        for invalid in [["--performance-seed", nonce], ["--demo", "--performance-seed", "../" + nonce], ["--demo", "--performance-seed", nonce, "--performance-check"]] {
            #expect(throws: PerformanceMetrics.OptionsError.self) { try PerformanceMetrics.seedID(arguments: invalid) }
        }
        #expect(throws: PerformanceMetrics.OptionsError.self) { try PerformanceMetrics.Options(arguments: ["--demo", "--performance-check", "--performance-cached-launch"]) }
    }
    @Test func explicitDemoAndBoundedArguments() throws {
        let base = ["--demo", "--performance-check"]
        #expect(try PerformanceMetrics.Options(arguments: base).idleSeconds == 5)
        #expect(try PerformanceMetrics.Options(arguments: base + ["--performance-idle-seconds", "600", "--performance-iterations", "10"]).iterations == 10)
        for invalid in [["--performance-check"], base + ["--performance-idle-seconds", "601"], base + ["--performance-idle-seconds", "-1"], base + ["--performance-idle-seconds", "NaN"], base + ["--performance-iterations", "100"], base + ["--performance-idle-seconds", "1", "--performance-idle-seconds", "2"]] {
            #expect(throws: PerformanceMetrics.OptionsError.self) { try PerformanceMetrics.Options(arguments: invalid) }
        }
    }
}
