import Foundation
import OSLog

/// Swift end of the Hark sidecar bridge. Spawns the bundled `hark-sidecar`
/// binary, speaks NDJSON over stdio (see `Sidecar/src/protocol.ts`), and
/// correlates responses to requests by `id`.
///
/// Public surface is `request(method:params:)` which returns the raw JSON
/// `result` payload as `Data` — callers decode with their own `Decodable`.
/// The convenience overload `request(method:_:)` does the decode inline.
///
/// Lifecycle: lazy-starts the process on the first request. Survives crashes
/// by re-spawning on the next request after a termination event.
@MainActor
final class AgentSidecar {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "AgentSidecar")
    private static let binaryName = "hark-sidecar"

    enum SidecarError: LocalizedError, CustomStringConvertible {
        case binaryNotFound
        case notRunning
        case server(message: String, code: String?)
        case malformedResponse

        var description: String {
            switch self {
            case .binaryNotFound: "Bundled sidecar binary not found"
            case .notRunning: "Sidecar is not running"
            case let .server(message, code):
                code.map { "[\($0)] \(message)" } ?? message
            case .malformedResponse: "Sidecar sent a malformed response"
            }
        }

        /// LocalizedError surfaces description via error.localizedDescription
        /// so the pill shows the real reason instead of "error 0".
        var errorDescription: String? { description }
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readBuffer = Data()

    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var nextRequestId: UInt64 = 0

    /// Builds the env to inject into the sidecar Process on each spawn. Called
    /// fresh per start so re-auth flows are picked up without re-instantiating.
    private let environmentProvider: @MainActor () -> [String: String]

    init(environmentProvider: @escaping @MainActor () -> [String: String] = {
        ProcessInfo.processInfo.environment
    }) {
        self.environmentProvider = environmentProvider
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Spawn the sidecar if it isn't already running.
    func start() throws {
        if let process, process.isRunning { return }
        guard let binaryURL = Bundle.main.url(forResource: Self.binaryName, withExtension: nil) else {
            throw SidecarError.binaryNotFound
        }

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.executableURL = binaryURL
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.environment = environmentProvider()
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.ingest(data)
            }
        }

        try proc.run()
        process = proc
        stdinPipe = inPipe
        stdoutPipe = outPipe
        readBuffer.removeAll(keepingCapacity: true)
        Self.logger.info("Sidecar started (pid \(proc.processIdentifier))")
    }

    /// Terminate the sidecar and fail all in-flight requests.
    func stop() {
        process?.terminate()
        handleTermination()
    }

    /// Send a request with optional pre-encoded JSON `params` (must be a JSON
    /// object/array/primitive). Returns the raw `result` field as JSON.
    func request(method: String, params: Data? = nil) async throws -> Data {
        if !isRunning { try start() }

        let id = nextId()
        let line = try buildRequestLine(id: id, method: method, params: params)

        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw SidecarError.notRunning
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[id] = continuation
            do {
                try stdin.write(contentsOf: line)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convenience: encode params and decode result with `JSONEncoder`/`JSONDecoder`.
    func request<R: Decodable>(
        method: String,
        params: some Encodable,
        result _: R.Type = R.self
    ) async throws
        -> R
    {
        let encoded = try JSONEncoder().encode(params)
        let data = try await request(method: method, params: encoded)
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// Convenience: no params, decode result.
    func request<R: Decodable>(method: String, result _: R.Type = R.self) async throws -> R {
        let data = try await request(method: method, params: nil)
        return try JSONDecoder().decode(R.self, from: data)
    }

    // MARK: - Private

    private func nextId() -> String {
        nextRequestId &+= 1
        return String(nextRequestId)
    }

    private func buildRequestLine(id: String, method: String, params: Data?) throws -> Data {
        var envelope: [String: Any] = [
            "kind": "request",
            "id": id,
            "method": method
        ]
        if let params {
            envelope["params"] = try JSONSerialization.jsonObject(with: params)
        }
        var data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        data.append(0x0A) // newline
        return data
    }

    private func ingest(_ chunk: Data) {
        readBuffer.append(chunk)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<newline)
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            if !lineData.isEmpty {
                handleLine(lineData)
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["kind"] as? String == "response",
            let id = json["id"] as? String else
        {
            Self.logger.debug("Ignored non-response line from sidecar")
            return
        }

        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            Self.logger.warning("Response for unknown id \(id, privacy: .public)")
            return
        }

        if json["ok"] as? Bool == true {
            let result = json["result"] ?? NSNull()
            do {
                let resultData = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                continuation.resume(returning: resultData)
            } catch {
                continuation.resume(throwing: error)
            }
        } else {
            let message = (json["error"] as? String) ?? "unknown server error"
            let code = json["code"] as? String
            continuation.resume(throwing: SidecarError.server(message: message, code: code))
        }
    }

    private func handleTermination() {
        if process != nil {
            Self.logger.warning("Sidecar process terminated")
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: SidecarError.notRunning)
        }
        pendingRequests.removeAll()
        readBuffer.removeAll(keepingCapacity: false)
    }
}
