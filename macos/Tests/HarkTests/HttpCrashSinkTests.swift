@testable import Hark
import XCTest

/// Tests for the opt-in HTTPS crash uploader. The sink's I/O is
/// covered by intercepting at the URLProtocol layer, which is the
/// canonical pattern for URLSession-based code. The pure JSON
/// builder is tested separately so we don't need URLProtocol just
/// to confirm the wire shape.
@MainActor
final class HttpCrashSinkTests: XCTestCase {
    // MARK: - JSON body shape (pure)

    func testJsonBodyIncludesAllPayloadFields() {
        let payload = CrashReporter.CrashPayload(
            kind: "SIGSEGV",
            detail: "Segmentation fault: 11",
            stack: ["frame 0", "frame 1"],
            signal: 11,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = HttpCrashSink.makeJsonBody(payload: payload, appVersion: "0.1.5", build: "1")

        XCTAssertEqual(body["kind"] as? String, "SIGSEGV")
        XCTAssertEqual(body["detail"] as? String, "Segmentation fault: 11")
        XCTAssertEqual(body["appVersion"] as? String, "0.1.5")
        XCTAssertEqual(body["build"] as? String, "1")
        XCTAssertEqual(body["signal"] as? Int, 11)
        XCTAssertEqual(body["signalName"] as? String, "SIGSEGV")
        XCTAssertEqual(body["stack"] as? [String], ["frame 0", "frame 1"])
        XCTAssertEqual(body["timestamp"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertNotNil(body["pid"])
    }

    func testJsonBodyOmitsSignalWhenNotASignal() {
        // NSException-driven crashes have no signal; the body should still
        // be valid JSON, just without `signal` / `signalName` keys.
        let payload = CrashReporter.CrashPayload(
            kind: "NSInternalInconsistencyException",
            detail: "...",
            stack: [],
            signal: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let body = HttpCrashSink.makeJsonBody(payload: payload, appVersion: "0.1.5", build: "1")
        XCTAssertNil(body["signal"])
        XCTAssertNil(body["signalName"])
    }

    // MARK: - Endpoint preferences

    func testEndpointStoreRoundTrip() {
        defer { CrashUploadPreferences.setEndpoint(nil) }
        XCTAssertNil(CrashUploadPreferences.endpointString)
        CrashUploadPreferences.setEndpoint("https://example.com/hark")
        XCTAssertEqual(CrashUploadPreferences.endpointString, "https://example.com/hark")
        CrashUploadPreferences.setEndpoint(nil)
        XCTAssertNil(CrashUploadPreferences.endpointString)
    }

    func testEndpointStoreTreatsEmptyAndWhitespaceAsAbsent() {
        defer { CrashUploadPreferences.setEndpoint(nil) }
        CrashUploadPreferences.setEndpoint("   ")
        XCTAssertNil(CrashUploadPreferences.endpointString)
        CrashUploadPreferences.setEndpoint("")
        XCTAssertNil(CrashUploadPreferences.endpointString)
    }

    func testBuildSinkRequiresHttps() {
        defer { CrashUploadPreferences.setEndpoint(nil) }
        // http:// rejected even if otherwise well-formed
        CrashUploadPreferences.setEndpoint("http://example.com/hark")
        XCTAssertNil(CrashUploadPreferences.buildSinkIfConfigured())

        CrashUploadPreferences.setEndpoint("https://example.com/hark")
        XCTAssertNotNil(CrashUploadPreferences.buildSinkIfConfigured())
    }

    func testBuildSinkReturnsNilForMalformedUrl() {
        defer { CrashUploadPreferences.setEndpoint(nil) }
        // Setting a totally malformed string still persists, but
        // buildSinkIfConfigured should refuse it.
        CrashUploadPreferences.setEndpoint("not a url at all")
        let sink = CrashUploadPreferences.buildSinkIfConfigured()
        // URL(string:) actually parses many strings permissively; the
        // critical contract is "scheme must be https." A bare string
        // with no scheme has nil scheme → refused.
        XCTAssertNil(sink)
    }

    // MARK: - HTTP capture round-trip (via URLProtocol injection)

    /// Captures every URLRequest the sink emits. URLProtocol-level
    /// interception is more robust than mocking URLSession's
    /// methods directly — it works against the real session and
    /// catches anything passing through the network stack.
    final class CaptureProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var captured: [(URLRequest, Data)] = []
        nonisolated(unsafe) static let lock = NSLock()

        // `override class func` is the canonical URLProtocol override
        // shape — Swift forwards it as static dispatch on a final class.
        // swiftlint:disable:next static_over_final_class
        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        // swiftlint:disable:next static_over_final_class
        override class func canonicalRequest(for r: URLRequest) -> URLRequest {
            r
        }

        override func startLoading() {
            let body = request.httpBody
                ?? request.httpBodyStream.flatMap { stream -> Data? in
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    let bufSize = 1024
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { buffer.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buffer, maxLength: bufSize)
                        if read <= 0 { break }
                        data.append(buffer, count: read)
                    }
                    return data
                }
                ?? Data()
            Self.lock.lock()
            Self.captured.append((request, body))
            Self.lock.unlock()
            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: nil
                ) else
            {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testCaptureSendsJsonPostToConfiguredEndpoint() async throws {
        CaptureProtocol.captured.removeAll()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        let session = URLSession(configuration: config)

        let url = try XCTUnwrap(URL(string: "https://collector.example/hark"))
        let sink = HttpCrashSink(endpoint: url, session: session)
        let payload = CrashReporter.CrashPayload(
            kind: "SIGABRT",
            detail: "abort()",
            stack: [],
            signal: 6,
            timestamp: Date()
        )
        sink.capture(payload)

        // capture() is fire-and-forget; let URLProtocol drain.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(CaptureProtocol.captured.count, 1)
        let (request, body) = CaptureProtocol.captured[0]
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Hark/") ?? false)

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["kind"] as? String, "SIGABRT")
        XCTAssertEqual(json?["signalName"] as? String, "SIGABRT")
    }
}
