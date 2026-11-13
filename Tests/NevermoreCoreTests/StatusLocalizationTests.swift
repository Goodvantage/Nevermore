import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct StatusLocalizationTests {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_CH")

    @Test func packagedBundleWinsWithoutEvaluatingGeneratedFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreBundleResolution-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Fixture.app/Contents/Resources", isDirectory: true)
        let candidate = resources.appendingPathComponent("Nevermore_NevermoreCore.bundle", isDirectory: true)
        let contents = candidate.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "fixture.core.localization", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        _ = try #require(Bundle(url: candidate))
        var fallbackCalls = 0
        let resolved = StatusLocalization.resolveResourceBundle(resourceDirectory: resources) {
            fallbackCalls += 1
            return Bundle.main
        }
        #expect(resolved.bundleURL.standardizedFileURL == candidate.standardizedFileURL)
        #expect(fallbackCalls == 0)
    }
    @Test func missingOrNilPackagedCandidateEvaluatesFallbackOnce() throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreMissingBundle-\(UUID())", isDirectory: true)
        for resources in [nil, absent] as [URL?] {
            var fallbackCalls = 0
            let resolved = StatusLocalization.resolveResourceBundle(resourceDirectory: resources) {
                fallbackCalls += 1
                return Bundle.main
            }
            #expect(resolved === Bundle.main)
            #expect(fallbackCalls == 1)
        }
    }
    @Test func bundledKeysHaveEnglishValues() throws {
        let bundle = try #require(Bundle(url: StatusLocalization.resourceBundleURL))
        #expect(bundle.localizations.contains("en"))
        #expect(bundle.localizations.contains("de"))
        for key in StatusLocalization.Key.allCases {
            // Every key must resolve; some format values require arguments.
            let file = try #require(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            let values = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            #expect(values[key.rawValue] != nil)
        }
    }
    @Test func explicitLocaleAndEnglishFallback() {
        #expect(StatusLocalization.text(.connecting, locale: english) == "Connecting…")
        #expect(StatusLocalization.text(.connecting, locale: german) == "Verbindung wird hergestellt…")
        #expect(StatusLocalization.text(.outboxOldReview, locale: german) == "Queued over 24 hours ago. Review before retrying.")
        #expect(StatusLocalization.text(.connecting, locale: Locale(identifier: "fr_FR")) == "Connecting…")
    }
    @Test func errorFormatArgumentsRetainValuesAndRedactedCopy() {
        #expect(StatusLocalization.errorDescription(RavenError.keychain(-25293), locale: german) == "Sicheres Speichern der Zugangsdaten fehlgeschlagen (Schlüsselbundfehler -25293).")
        let denied = StatusLocalization.errorDescription(RavenError.http(403, "PermissionError"), locale: english)
        #expect(denied.contains("HTTP 403 (PermissionError)"))
        #expect(!denied.contains("%@") && !denied.contains("%ld"))
        let budget = StatusLocalization.text(.stagingBudget, locale: german, arguments: [Int64(1_048_576)])
        // Grouping punctuation varies with the OS locale-data version. Check
        // the complete integer payload without pinning that punctuation.
        let digits = budget.unicodeScalars.filter { (48...57).contains($0.value) }
        #expect(String(String.UnicodeScalarView(digits)) == "1048576")
        #expect(!budget.contains("%lld"))
        #expect(StatusLocalization.errorDescription(RavenError.transport, locale: german).hasPrefix("Die Website"))
    }
    @Test func stateLabelsNeverChangePersistedValues() throws {
        #expect(SendState.needsReview.localizedLabel(locale: english) == "Review required")
        #expect(SendState.needsReview.localizedLabel(locale: german) == "Überprüfung erforderlich")
        #expect(SendState.needsReview.rawValue == "needsReview")
        let encoded = try JSONEncoder().encode(SendState.needsReview)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"needsReview\"")
        #expect(try JSONDecoder().decode(SendState.self, from: encoded) == .needsReview)
    }
}
