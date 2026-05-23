@testable import Hark
import XCTest

@MainActor
final class AgentSidecarTests: XCTestCase {
    struct PingResult: Decodable {
        let pong: Double
        let echoed: Echoed?

        struct Echoed: Decodable {
            let hello: String
        }
    }

    struct PingParams: Encodable {
        let hello: String
    }

    /// End-to-end smoke test: spawn the bundled sidecar binary, ping it,
    /// expect a pong with the params we sent back.
    func testPingRoundTrip() async throws {
        guard Bundle.main.url(forResource: "hark-sidecar", withExtension: nil) != nil else {
            throw XCTSkip("hark-sidecar not bundled in test host — run `./scripts/build-sidecar.sh` first.")
        }

        let sidecar = AgentSidecar()
        defer { sidecar.stop() }

        let before = Date()
        let result: PingResult = try await sidecar.request(
            method: "ping",
            params: PingParams(hello: "hark"),
            result: PingResult.self
        )
        let after = Date()

        XCTAssertEqual(result.echoed?.hello, "hark")
        XCTAssertGreaterThan(result.pong, 0)

        // Round-trip should be well under a second for a healthy ping.
        let elapsed = after.timeIntervalSince(before)
        XCTAssertLessThan(elapsed, 2.0, "Ping round-trip should be quick; got \(elapsed)s")
    }

    /// Unknown methods should surface as a server error with the documented code.
    func testUnknownMethodError() async throws {
        guard Bundle.main.url(forResource: "hark-sidecar", withExtension: nil) != nil else {
            throw XCTSkip("hark-sidecar not bundled in test host.")
        }

        let sidecar = AgentSidecar()
        defer { sidecar.stop() }

        struct EmptyResult: Decodable {}
        do {
            _ = try await sidecar.request(method: "no.such.method", result: EmptyResult.self)
            XCTFail("Expected unknown_method error")
        } catch let AgentSidecar.SidecarError.server(_, code) {
            XCTAssertEqual(code, "unknown_method")
        }
    }

    /// If a sidecar method doesn't respond within the per-request timeout,
    /// the request must resolve with `.timedOut` and `pendingRequests` must
    /// be empty afterward. Otherwise a hung Claude call would leak a
    /// CheckedContinuation and the next request could collide on the id.
    /// We don't have a "sleep" method in the sidecar to force a timeout,
    /// so we use `ping` with an aggressive 1ms timeout — the sidecar
    /// can't possibly reply that fast.
    func testRequestTimesOut() async throws {
        guard Bundle.main.url(forResource: "hark-sidecar", withExtension: nil) != nil else {
            throw XCTSkip("hark-sidecar not bundled in test host.")
        }

        let sidecar = AgentSidecar()
        defer { sidecar.stop() }

        struct PingParamsBody: Encodable { let hello: String }
        do {
            let _: PingResult = try await sidecar.request(
                method: "ping",
                params: PingParamsBody(hello: "hark"),
                result: PingResult.self,
                timeout: 0.001
            )
            XCTFail("Expected timeout error")
        } catch let AgentSidecar.SidecarError.timedOut(method, _) {
            XCTAssertEqual(method, "ping")
        }
    }

    /// After a timeout the sidecar should still be usable for follow-up
    /// requests — `pendingRequests` cleared, process still alive. Without
    /// this guarantee a single slow Claude call would wedge the channel
    /// permanently.
    func testSidecarSurvivesTimeoutAndAcceptsNextRequest() async throws {
        guard Bundle.main.url(forResource: "hark-sidecar", withExtension: nil) != nil else {
            throw XCTSkip("hark-sidecar not bundled in test host.")
        }

        let sidecar = AgentSidecar()
        defer { sidecar.stop() }

        struct PingParamsBody: Encodable { let hello: String }

        // Trigger a timeout
        do {
            let _: PingResult = try await sidecar.request(
                method: "ping",
                params: PingParamsBody(hello: "first"),
                result: PingResult.self,
                timeout: 0.001
            )
            XCTFail("expected timeout")
        } catch AgentSidecar.SidecarError.timedOut {
            // expected
        }

        // Follow-up request should succeed normally with a reasonable
        // timeout — process is still alive, channel is recovered.
        let result: PingResult = try await sidecar.request(
            method: "ping",
            params: PingParamsBody(hello: "follow-up"),
            result: PingResult.self,
            timeout: 5
        )
        XCTAssertEqual(result.echoed?.hello, "follow-up")
    }

    /// Auto-respawn on crash: after we call `stop()` and the process
    /// dies, the very next `request(...)` should transparently spawn a
    /// fresh sidecar and serve the request. This is the production
    /// recovery path; without it a one-off Bun panic would brick the
    /// channel until the user relaunched Hark.
    func testSidecarAutoRespawnsAfterStop() async throws {
        guard Bundle.main.url(forResource: "hark-sidecar", withExtension: nil) != nil else {
            throw XCTSkip("hark-sidecar not bundled in test host.")
        }

        let sidecar = AgentSidecar()
        defer { sidecar.stop() }

        struct PingParamsBody: Encodable { let hello: String }

        // First request — spawns the sidecar
        let first: PingResult = try await sidecar.request(
            method: "ping",
            params: PingParamsBody(hello: "before"),
            result: PingResult.self
        )
        XCTAssertEqual(first.echoed?.hello, "before")
        XCTAssertTrue(sidecar.isRunning)

        // Kill it (mimics a Bun crash)
        sidecar.stop()
        XCTAssertFalse(sidecar.isRunning)

        // Next request should re-spawn and succeed
        let second: PingResult = try await sidecar.request(
            method: "ping",
            params: PingParamsBody(hello: "after"),
            result: PingResult.self
        )
        XCTAssertEqual(second.echoed?.hello, "after")
        XCTAssertTrue(sidecar.isRunning)
    }

    /// Multiple in-flight requests get correlated correctly by id. If the
    /// pendingRequests map weren't keyed properly, responses would resolve
    /// the wrong continuation. We send 5 pings concurrently and confirm
    /// each gets its own echoed payload back.
    func testConcurrentRequestsAreCorrelatedById() async throws {
        guard Bundle.main.url(forResource: "hark-sidecar", withExtension: nil) != nil else {
            throw XCTSkip("hark-sidecar not bundled in test host.")
        }

        let sidecar = AgentSidecar()
        defer { sidecar.stop() }

        struct Params: Encodable { let hello: String }
        let labels = ["one", "two", "three", "four", "five"]

        let results = try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for label in labels {
                group.addTask { @MainActor in
                    let result: PingResult = try await sidecar.request(
                        method: "ping",
                        params: Params(hello: label),
                        result: PingResult.self,
                        timeout: 5
                    )
                    return (label, result.echoed?.hello)
                }
            }
            var collected: [String: String?] = [:]
            for try await (sent, echoed) in group {
                collected[sent] = echoed
            }
            return collected
        }

        // Every send must round-trip to its OWN echo, not someone else's.
        XCTAssertEqual(results.count, labels.count)
        for label in labels {
            let echoed = results[label].flatMap { $0 }
            XCTAssertEqual(echoed, label, "response for \(label) was \(String(describing: echoed))")
        }
    }
}
