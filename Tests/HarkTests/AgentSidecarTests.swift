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
}
