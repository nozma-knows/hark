import AVFoundation
@testable import Hark
import XCTest

/// End-to-end coverage of the audio → Whisper → orchestrator pipeline.
///
/// Every layer below is unit-tested, but the integration — real samples
/// hitting real WhisperKit through real Transcriber → real
/// RecordingPipeline — has no automated coverage until this file. A
/// regression here is exactly the kind a user would discover first
/// (i.e., "I said something and nothing happened"), so it deserves a
/// real test rather than relying on manual hotkey-driven checks.
///
/// Strategy:
///   - Synthesize voice with macOS `say` so we don't commit a binary
///     audio fixture (and so the test always has fresh, fully-
///     attribution-clean input).
///   - Resample/repack via `afconvert` to the exact format
///     AudioRecorder produces (16 kHz mono Float32 little-endian).
///   - Parse the WAV header to extract the Float32 sample array.
///   - Drive Transcriber + RecordingPipeline against that sample
///     array and assert the AppState that results.
///
/// Skip conditions (any of these make the test XCTSkip rather than
/// fail, so CI without a model download stays green):
///   - tiny.en model not downloaded (would otherwise pull ~75 MB
///     during the test)
///   - macOS `say` or `afconvert` unavailable (shouldn't happen on
///     a real Mac runner, defensive only)
@MainActor
final class E2ETranscribePipelineTests: XCTestCase {
    /// Pick the best downloaded model: prefer small.en (more accurate on
    /// synthetic voices) but fall back to tiny.en if that's all that's
    /// present. Skip the test entirely if neither is downloaded so CI
    /// without a model stays green.
    private func pickModel(for transcriber: Transcriber) throws -> WhisperModel {
        if transcriber.isDownloaded(.smallEn) { return .smallEn }
        if transcriber.isDownloaded(.tinyEn) { return .tinyEn }
        throw XCTSkip("no Whisper model downloaded — `await transcriber.select(.tinyEn)` to populate.")
    }

    /// Load `model` and skip if WhisperKit couldn't actually bring it up
    /// to `.ready`. `isDownloaded` only checks for the AudioEncoder
    /// marker file, but CI runners can be left with a half-finished
    /// download (encoder present, weight files still `.incomplete`),
    /// which makes `loadIfNeeded` transition to `.failed` rather than
    /// `.ready`. Without this guard the subsequent `transcribe` throws
    /// `modelNotLoaded` and the test fails noisily on what is really an
    /// environmental issue.
    private func loadModelOrSkip(_ model: WhisperModel, on transcriber: Transcriber) async throws {
        await transcriber.loadIfNeeded(model)
        guard case .ready = transcriber.state else {
            throw XCTSkip(
                "Whisper model couldn't load (state=\(transcriber.state)) — likely a partial download on this runner."
            )
        }
    }

    func testAudioToTranscriptProducesNonEmpty() async throws {
        // The end-to-end claim: `say` audio at 16 kHz Float32, fed into
        // Transcriber.transcribe, produces a non-empty string. We don't
        // assert exact content — Whisper's accuracy on synthetic voices
        // varies by model and version, and pinning a specific phrase
        // would flake. Empty output IS a regression, though (means the
        // model isn't wired correctly or the audio buffer shape changed).
        let transcriber = Transcriber()
        let model = try pickModel(for: transcriber)

        let samples = try await synthesizeSamples(saying: "open linear application")
        XCTAssertGreaterThan(samples.count, 8000, "expected at least 0.5s of audio")

        try await loadModelOrSkip(model, on: transcriber)
        let raw = try await transcriber.transcribe(samples: samples)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(
            trimmed.isEmpty,
            "Whisper returned an empty transcript for \(samples.count) samples — pipeline regression?"
        )
    }

    func testTranscribePipelineRoutesToCommandResult() async throws {
        // Same audio shape, but routed through RecordingPipeline.deliver
        // with .command so the result lands in AppState.commandResult.
        // Exercises the executeCommand sidecar path end-to-end against a
        // stub sidecar that echoes back a known summary — confirms the
        // dispatcher → AppState wiring without depending on a real
        // sidecar process.
        let transcriber = Transcriber()
        let model = try pickModel(for: transcriber)

        let samples = try await synthesizeSamples(saying: "open linear application")
        try await loadModelOrSkip(model, on: transcriber)
        let transcript = try await transcriber.transcribe(samples: samples)

        let appState = AppState()
        let pipeline = RecordingPipeline(
            appState: appState,
            sidecar: StubSidecar.executeOnly(
                summary: "Routed: \(transcript.lowercased())",
                succeeded: true
            )
        )
        // pipeline.deliver early-returns if transcript is blank; pass a
        // canned phrase in that case so the test still verifies the
        // routing logic.
        let safeTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "open linear"
            : transcript
        await pipeline.deliver(safeTranscript, trigger: .command)

        XCTAssertEqual(appState.commandResult?.succeeded, true)
        XCTAssertTrue(
            appState.commandResult?.summary.contains("Routed:") ?? false,
            "pill should show the stub sidecar's summary; got \(appState.commandResult?.summary ?? "nil")"
        )
    }

    // MARK: - Helpers

    /// Run `say <text>` → `afconvert` to produce a 16 kHz mono Float32 WAV,
    /// then parse the header and return the sample array. AudioRecorder's
    /// production output is byte-identical to what `afconvert` writes here,
    /// so the transcriber receives the same shape it does at runtime.
    private func synthesizeSamples(saying text: String) async throws -> [Float] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hark-e2e-\(UUID().uuidString)")
        let aiffURL = tmp.appendingPathExtension("aiff")
        let wavURL = tmp.appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: aiffURL)
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Explicit voice. The default voice on a fresh Mac (or after a
        // recent system update) often resolves to a "needs download"
        // entry that say silently truncates to ~5ms, which Whisper can't
        // do anything with. Alex is a built-in voice present on every
        // macOS install since 10.7. If it's been deleted we XCTSkip
        // rather than fail noisily.
        try runProcess(executable: "/usr/bin/say", args: ["-v", "Alex", text, "-o", aiffURL.path])
        guard FileManager.default.fileExists(atPath: aiffURL.path) else {
            throw XCTSkip("`say` produced no output — synth voice may be unavailable.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: aiffURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        if size < 1024 {
            throw XCTSkip(
                "`say -v Alex` produced suspiciously small file (\(size)B) — voice may be uninstalled on this machine."
            )
        }
        try runProcess(
            executable: "/usr/bin/afconvert",
            args: [
                aiffURL.path,
                wavURL.path,
                "-d", "LEF32@16000",
                "-f", "WAVE",
                "--channels", "1"
            ]
        )

        return try readFloat32SamplesAVAudioFile(at: wavURL)
    }

    /// Load a 16 kHz mono Float32 WAV via AVAudioFile and return a flat
    /// Float array. Robust to chunk ordering / extension chunks that
    /// hand-rolled WAV parsers stumble on.
    private func readFloat32SamplesAVAudioFile(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else
        {
            throw NSError(
                domain: "E2E",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "couldn't allocate PCM buffer"]
            )
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(
                domain: "E2E",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "PCM buffer has no float channel data"]
            )
        }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    /// Run a subprocess synchronously and throw if it exits non-zero.
    /// Used for `say` and `afconvert` — both should be fast and
    /// deterministic on macOS.
    private func runProcess(executable: String, args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = nil
        proc.standardError = nil
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw XCTSkip("\(executable) failed with status \(proc.terminationStatus)")
        }
    }
}

/// Minimal sidecar stub for the executeCommand path — returns a canned
/// result without spinning up the real Bun process. Class because
/// SidecarRequesting is `AnyObject`-constrained.
@MainActor
private final class StubSidecar: SidecarRequesting {
    private let response: Encodable

    init(response: Encodable) {
        self.response = response
    }

    static func executeOnly(summary: String, succeeded: Bool) -> StubSidecar {
        struct ExecuteResult: Encodable {
            let summary: String
            let succeeded: Bool
        }
        return StubSidecar(response: ExecuteResult(summary: summary, succeeded: succeeded))
    }

    func request<R: Decodable>(
        method _: String,
        params _: some Encodable,
        result _: R.Type,
        timeout _: TimeInterval
    ) async throws
        -> R
    {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(R.self, from: data)
    }
}
