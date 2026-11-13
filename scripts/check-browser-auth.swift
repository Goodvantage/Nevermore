import Foundation

/// A headless runner for the same callback regressions used by --self-check.
@main struct BrowserAuthenticationRegression {
    @MainActor static func main() async throws {
        let results = try await BrowserAuthenticationSelfChecks.run()
        for (label, passed) in results { print("\(passed ? "PASS" : "FAIL") \(label)") }
        if results.contains(where: { !$0.1 }) { exit(1) }
    }
}
