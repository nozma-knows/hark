@testable import Hark
import XCTest

/// `UpdateManager.detectValidSigningKey(in:)` is the gate that determines
/// whether Sparkle's background checker runs and whether the "Check for
/// Updates…" menu is live. With an empty key, Sparkle silently disables
/// EdDSA signature verification — so this gate is the only thing between
/// a misconfigured bundle and an attacker-controlled update.
///
/// We pin down every input shape the production code could see in the
/// `Bundle.main.infoDictionary` at runtime.
final class UpdateManagerTests: XCTestCase {
    // MARK: - The four real failure modes

    func testNilInfoDictReturnsFalse() {
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: nil))
    }

    func testMissingKeyReturnsFalse() {
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: [:]))
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["OtherKey": "value"]))
    }

    func testEmptyStringReturnsFalse() {
        // The XcodeGen template ships an empty default for SUPublicEDKey
        // to keep the build green before keys exist. We must treat that
        // as "not configured" — anything else would silently disable
        // update verification on every dev build.
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": ""]))
    }

    func testWhitespaceOnlyReturnsFalse() {
        // Defensive: a developer might paste "   " or "\n" thinking it's
        // a placeholder. Trimming catches all of these.
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": "   "]))
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": "\n"]))
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": "\t\n  "]))
    }

    // MARK: - Valid populated keys

    func testRealLookingKeyReturnsTrue() {
        // Real Sparkle EdDSA public keys are 44-char base64. Doesn't matter
        // for our test — we only check non-empty after trimming.
        let realKey = "abc123XYZdefABCDEFGHIJKLMNOPQRSTUVWXYZab+/=="
        XCTAssertTrue(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": realKey]))
    }

    func testShortKeyStillReturnsTrue() {
        // We don't validate FORMAT here — only presence. Sparkle handles
        // the actual cryptographic verification; if the key is malformed,
        // Sparkle rejects updates with its own error. This gate's job is
        // narrower: was a key provided at all?
        XCTAssertTrue(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": "x"]))
    }

    func testWhitespaceAroundKeyStillReturnsTrue() {
        // Trim leading/trailing whitespace but accept a real key inside.
        XCTAssertTrue(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": "  real-key  "]))
    }

    // MARK: - Non-string values are rejected (defensive)

    func testNumericValueReturnsFalse() {
        // Someone might accidentally type `SUPublicEDKey: 12345` in YAML
        // and end up with a Number in the plist. We reject anything that
        // isn't a String.
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": 12345 as Any]))
    }

    func testBooleanValueReturnsFalse() {
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": true as Any]))
    }

    func testArrayValueReturnsFalse() {
        XCTAssertFalse(UpdateManager.detectValidSigningKey(in: ["SUPublicEDKey": ["key1", "key2"] as Any]))
    }
}
