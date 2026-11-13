import Foundation
import Security
import Testing

/// Whether this test process can write Keychain items, which every test that
/// persists tokens (directly or through a refresh) needs.
///
/// The forge's Mac runner runs jobs as a system LaunchDaemon. A daemon's
/// default keychain is the System keychain, so each write fails with
/// `errSecWrPerm` (-61), and no per-job default keychain can be set. Unsigned
/// test runners can also be refused outright. Those tests are skipped there
/// with `unavailableReason` instead of passing vacuously; they still run on a
/// developer's Mac. Any other failure counts as writable, so the test runs and
/// reports the real error.
enum TestKeychain {
    private static let deniedStatuses: Set<OSStatus> = [errSecWrPerm, errSecInteractionNotAllowed, errSecMissingEntitlement]

    static let isWritable: Bool = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Nevermore.tests.keychain-probe",
            kSecAttrAccount as String: UUID().uuidString,
        ]
        var item = probe
        item[kSecValueData as String] = Data()
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { SecItemDelete(probe as CFDictionary) }
        return !deniedStatuses.contains(status)
    }()

    static let unavailableReason: Comment = "Needs a writable default keychain; a LaunchDaemon CI runner has none"
}
