@testable import Hark
import XCTest

/// `ClaudeUsage` is persisted across launches via UserDefaults; the math
/// happens in `add(...)`. Direct unit tests prevent a regression where
/// e.g., cache-creation tokens stop being counted toward the running
/// total or `lastUsedAt` stops advancing.
@MainActor
final class ClaudeUsageTests: XCTestCase {
    func testAddAccumulates() {
        var u = ClaudeUsage()
        u.add(input: 100, output: 50, cacheRead: 10, cacheCreation: 5)
        XCTAssertEqual(u.inputTokens, 100)
        XCTAssertEqual(u.outputTokens, 50)
        XCTAssertEqual(u.cacheReadTokens, 10)
        XCTAssertEqual(u.cacheCreationTokens, 5)
        XCTAssertEqual(u.requestCount, 1)
        XCTAssertNotNil(u.lastUsedAt)
    }

    func testAddIsCumulative() {
        var u = ClaudeUsage()
        u.add(input: 10, output: 5, cacheRead: 0, cacheCreation: 0)
        u.add(input: 20, output: 7, cacheRead: 3, cacheCreation: 1)
        XCTAssertEqual(u.inputTokens, 30)
        XCTAssertEqual(u.outputTokens, 12)
        XCTAssertEqual(u.cacheReadTokens, 3)
        XCTAssertEqual(u.cacheCreationTokens, 1)
        XCTAssertEqual(u.requestCount, 2)
    }

    func testTotalTokensSumsAllFields() {
        var u = ClaudeUsage()
        u.add(input: 100, output: 50, cacheRead: 25, cacheCreation: 10)
        XCTAssertEqual(u.totalTokens, 185)
    }

    func testLastUsedAtAdvances() throws {
        var u = ClaudeUsage()
        u.add(input: 1, output: 1, cacheRead: 0, cacheCreation: 0)
        let first = try XCTUnwrap(u.lastUsedAt)
        // Force a small delay; lastUsedAt should bump forward on next add.
        Thread.sleep(forTimeInterval: 0.01)
        u.add(input: 1, output: 1, cacheRead: 0, cacheCreation: 0)
        let second = try XCTUnwrap(u.lastUsedAt)
        XCTAssertGreaterThan(second, first)
    }
}
