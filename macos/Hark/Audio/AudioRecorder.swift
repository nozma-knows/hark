// AVFoundation's AVAudioPCMBuffer / AVAudioConverter aren't `Sendable` in
// Swift 6 strict-concurrency mode even though they're trivially safe to
// pass into a synchronous-callback closure like the one we use here.
// `@preconcurrency` silences the cross-module warning without affecting
// our own concurrency guarantees (the tap callback runs on a private
// audio thread; we hop back to MainActor explicitly via Task).
@preconcurrency import AVFoundation
import Foundation
import Observation

/// Captures microphone audio via `AVAudioEngine`, downsamples to 16 kHz mono
/// Float32 (Whisper's expected input), and exposes the running buffer + a
/// recent-level meter on the main actor.
///
/// The tap callback runs off the main thread; conversion happens there and
/// the converted samples + RMS level are hopped back to the main actor for
/// observable updates. Audio buffers are small (~50 ms each) so the cost of
/// the actor hop is negligible compared to AVAudioEngine's internal latency.
@MainActor
@Observable
final class AudioRecorder {
    enum State: Equatable {
        case idle
        case recording
        case processing
    }

    enum RecorderError: Error {
        case alreadyRecording
        case converterUnavailable
    }

    private(set) var state: State = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var level: Float = 0

    private static let targetSampleRate: Double = 16000
    static let maxDuration: TimeInterval = 60
    private static let maxSampleCount = Int(targetSampleRate * maxDuration)

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat

    /// 16 kHz mono Float32 samples captured so far this session.
    /// Capped at `maxDuration` seconds (`maxSampleCount` Float values) —
    /// once full, the oldest samples are dropped FIFO so the buffer holds a
    /// sliding 60 s window rather than growing without bound.
    private var samples: [Float] = []
    private var startTime: Date?
    private var durationTimer: Timer?

    init() {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false
            ) else
        {
            preconditionFailure("Failed to construct 16kHz mono Float32 AVAudioFormat")
        }
        targetFormat = format
    }

    /// Begin capturing. Throws if the audio engine fails to start (e.g. no
    /// input device available) or if we can't build a converter from the
    /// hardware format to 16 kHz mono.
    func start() throws {
        guard state == .idle else { throw RecorderError.alreadyRecording }

        samples.removeAll(keepingCapacity: true)
        duration = 0
        level = 0

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        let target = targetFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let result = Self.downsampleAndMeasure(buffer, converter: converter, target: target)
            guard !result.samples.isEmpty else { return }
            let samples = result.samples
            let level = result.level
            Task { @MainActor [weak self] in
                self?.ingest(samples, level: level)
            }
        }

        try engine.start()
        state = .recording
        startTime = Date()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickDuration() }
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }

    /// Stop capture and return the accumulated 16 kHz mono Float32 samples.
    /// Caller is responsible for passing these to transcription (PR 6+).
    @discardableResult
    func stop() -> [Float] {
        guard state == .recording else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        durationTimer?.invalidate()
        durationTimer = nil
        startTime = nil

        let finalSamples = samples
        samples.removeAll(keepingCapacity: false)
        state = .idle
        level = 0
        return finalSamples
    }

    private func ingest(_ newSamples: [Float], level: Float) {
        samples.append(contentsOf: newSamples)
        if samples.count > Self.maxSampleCount {
            samples.removeFirst(samples.count - Self.maxSampleCount)
        }
        self.level = level
    }

    private func tickDuration() {
        guard let startTime else { return }
        duration = Date().timeIntervalSince(startTime)
    }

    /// Convert a hardware-format input buffer to 16 kHz mono Float32 and
    /// compute the RMS level of the converted samples in one pass.
    nonisolated private static func downsampleAndMeasure(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat
    )
        -> (samples: [Float], level: Float)
    {
        let inputFrames = AVAudioFrameCount(input.frameLength)
        guard inputFrames > 0 else { return ([], 0) }

        // Convert proportionally; round up to avoid losing the tail sample.
        let ratio = target.sampleRate / input.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputFrames) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            return ([], 0)
        }

        // `providerFlag` lives in a reference-typed box so the converter's
        // input callback (which Swift 6 sees as @Sendable even though
        // AVAudioConverter calls it synchronously) can mutate the flag
        // without tripping captured-var diagnostics. The callback fires
        // exactly twice — once to provide the buffer, then again to
        // signal "no more data" — so this is just plumbing for the
        // call-once contract AVAudioConverter expects.
        let providerFlag = ProviderFlag()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPtr in
            if providerFlag.called {
                statusPtr.pointee = .noDataNow
                return nil
            }
            providerFlag.called = true
            statusPtr.pointee = .haveData
            return input
        }

        guard
            status != .error, output.frameLength > 0,
            let channelData = output.floatChannelData?.pointee else
        {
            return ([], 0)
        }

        let count = Int(output.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))

        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(count))

        return (samples, rms)
    }

    /// Reference-typed flag used inside the AVAudioConverter input
    /// callback. See `downsampleAndMeasure` for rationale.
    ///
    /// Threading / lifetime contract: `ProviderFlag` is created on the
    /// audio-tap thread, captured by the `convert(to:error:withInputFrom:)`
    /// closure, and accessed ONLY from inside `AVAudioConverter.convert` —
    /// which calls its input callback synchronously, on the calling
    /// thread, exactly twice per invocation. There is no concurrent
    /// access in practice; the `@unchecked Sendable` annotation only
    /// satisfies Swift 6's static checker for the `@Sendable` closure
    /// signature AVAudioConverter declares. Since the flag is a stack-
    /// local that doesn't outlive `downsampleAndMeasure`, no lifetime
    /// concern exists either.
    private final class ProviderFlag: @unchecked Sendable {
        var called = false
    }
}
