import Foundation
import Observation
import OSLog

// WhisperKit isn't marked Sendable yet; @preconcurrency suppresses the actor
// crossing warnings. We only ever touch the instance from this @MainActor
// class, so the runtime semantics are correct.
@preconcurrency import WhisperKit

/// Manages WhisperKit's lifecycle (load → ready → transcribe) and exposes its
/// state on the main actor so the panel and Settings UI can bind to it.
///
/// WhisperKit's own async API does the heavy lifting off the main thread; we
/// just gate state transitions and provide a clean `transcribe(samples:)`
/// surface for the AppDelegate to call when recording stops.
@MainActor
@Observable
final class Transcriber {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Transcriber")

    enum State: Equatable {
        case unloaded
        case downloading(WhisperModel, progress: Double)
        case loading(WhisperModel)
        case ready(WhisperModel)
        case transcribing(WhisperModel)
        case failed(String)
    }

    private static let selectedModelDefaultsKey = "co.milbo.hark.selectedModel"

    private(set) var state: State = .unloaded

    /// Wall-clock when the current load began, or nil when not loading.
    /// Set on entering `.loading`, cleared on `.ready`/`.failed`. The
    /// panel reads this to decide whether to show the "Warming up
    /// Whisper…" pill — only fires when load exceeds `PanelViewModel.
    /// loadingIndicatorGrace`, so quick warm-cache loads stay invisible.
    private(set) var loadingStartedAt: Date?

    /// Model the user has chosen to use. Persisted across launches.
    /// Mutate via `select(_:)` to also trigger download/load.
    private(set) var selectedModel: WhisperModel = {
        let raw = UserDefaults.standard.string(forKey: Transcriber.selectedModelDefaultsKey)
        return raw.flatMap(WhisperModel.init(rawValue:)) ?? .default
    }()

    /// Folder where WhisperKit caches downloaded model weights.
    /// `~/Library/Application Support/Hark/Models/` so models survive app
    /// upgrades and the user can audit / delete them.
    static let modelsDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = base.appending(path: "Hark/Models", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var whisperKit: WhisperKit?
    private var loadedModel: WhisperModel?

    /// Whether the given model's files are already on disk. WhisperKit's
    /// HuggingFace downloader writes to a nested path under `modelsDirectory`,
    /// so we check the AudioEncoder marker at the real location:
    ///   <base>/models/argmaxinc/whisperkit-coreml/<variant>/AudioEncoder.mlmodelc
    func isDownloaded(_ model: WhisperModel) -> Bool {
        let encoder = Self.modelsDirectory
            .appending(path: "models/argmaxinc/whisperkit-coreml/\(model.variant)/AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    /// Update the user's chosen model, persist it, and load it (downloading
    /// first if needed). Cheap if `model` is already loaded.
    func select(_ model: WhisperModel) async {
        if selectedModel != model {
            selectedModel = model
            UserDefaults.standard.set(model.rawValue, forKey: Self.selectedModelDefaultsKey)
        }
        await loadIfNeeded(model)
    }

    /// Bootstrap on app launch — loads the previously selected model in the
    /// background so the first dictation doesn't pay the load cost.
    func bootstrap() {
        let model = selectedModel
        Task { await loadIfNeeded(model) }
    }

    /// Download the model if needed and load it into memory. No-op if
    /// already loaded.
    func loadIfNeeded(_ model: WhisperModel) async {
        if loadedModel == model, whisperKit != nil {
            state = .ready(model)
            return
        }

        do {
            if !isDownloaded(model) {
                state = .downloading(model, progress: 0)
                _ = try await WhisperKit.download(
                    variant: model.variant,
                    downloadBase: Self.modelsDirectory
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(model, progress: progress.fractionCompleted)
                    }
                }
            }

            state = .loading(model)
            loadingStartedAt = Date()
            // `prewarm: true` + `load: true` force all CoreML model loading
            // (MelSpectrogram, AudioEncoder, TextDecoder) to happen here at
            // init time. Without these, WhisperKit lazy-loads the models
            // during the first transcribe call — adding ~15-20s of CoreML
            // wake-up to that one call, which trips our timeout. The
            // bootstrap path runs in the background at app launch, so paying
            // the cost here is invisible to the user.
            let config = WhisperKitConfig(
                model: model.variant,
                downloadBase: Self.modelsDirectory,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true
            )
            let kit = try await WhisperKit(config)
            whisperKit = kit
            loadedModel = model
            state = .ready(model)
            loadingStartedAt = nil
            Self.logger.info("Loaded model \(model.variant, privacy: .public)")
        } catch {
            let message = String(describing: error)
            Self.logger.error("Model load failed: \(message, privacy: .public)")
            state = .failed(message)
            loadingStartedAt = nil
        }
    }

    /// Hard ceiling on a single transcribe call. WhisperKit occasionally hangs
    /// on degenerate inputs (e.g., near-silence with VAD enabled) and there's
    /// no built-in timeout — without this, the pill is stuck on "Transcribing"
    /// with no recovery short of quitting the app. 30s is generous: a 60s
    /// recording on small.en typically completes in 3–8s once the model is
    /// warm, which it always is by this point (prewarm:true at load).
    private static let transcribeTimeout: Duration = .seconds(30)

    /// Tracks an in-flight transcribe so the UI can force-cancel and recover
    /// the pill state without quitting the app. Nil when idle.
    private var inFlight: TranscribeJob?

    /// Transcribe 16 kHz mono Float32 samples to a single string. Joins
    /// segments with a space. Throws if no model is loaded, the call times
    /// out, or WhisperKit returns an error. The `state` is guaranteed to
    /// return to `.ready` on every exit path (success, throw, or cancel).
    func transcribe(samples: [Float]) async throws -> String {
        guard let kit = whisperKit, let model = loadedModel else {
            throw TranscriberError.modelNotLoaded
        }
        state = .transcribing(model)
        defer {
            state = .ready(model)
            inFlight = nil
        }

        let started = Date()
        let secondsOfAudio = Double(samples.count) / 16000.0
        Self.logger.info(
            "Transcribe start: \(samples.count) samples (\(secondsOfAudio, format: .fixed(precision: 2))s)"
        )

        let job = TranscribeJob()
        inFlight = job

        // WhisperKit isn't Sendable in Swift 6 strict mode, but the
        // transcribe call doesn't actually touch shared mutable state —
        // it consumes the audio array, runs CoreML, returns segments.
        // Wrap the reference so the @Sendable detached-task closure can
        // capture it without tripping diagnostics.
        let kitBox = SendableBox(kit)

        do {
            let text = try await job.run(timeout: Self.transcribeTimeout) {
                let results = try await kitBox.value.transcribe(audioArray: samples)
                return results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let elapsed = Date().timeIntervalSince(started)
            Self.logger.info(
                "Transcribe done in \(elapsed, format: .fixed(precision: 2))s, \(text.count) chars"
            )
            return text
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            let errorDesc = String(describing: error)
            Self.logger.error(
                "Transcribe failed after \(elapsed, format: .fixed(precision: 2))s: \(errorDesc, privacy: .public)"
            )
            throw error
        }
    }

    /// User-triggered escape hatch from a stuck transcribe. Resolves the
    /// in-flight continuation with `.cancelled` (if there is one), and
    /// resets state to `.ready` synchronously so the pill snaps out of
    /// "Transcribing" immediately. Safe to call when nothing's running —
    /// it's a no-op.
    func cancelInFlight() {
        guard let job = inFlight else { return }
        Self.logger.info("Force-cancelling in-flight transcribe")
        job.cancel()
        if let model = loadedModel {
            state = .ready(model)
        }
        inFlight = nil
    }
}

/// Carry a non-`Sendable` reference across an `@Sendable` closure
/// boundary. Used for `WhisperKit` (third-party, marked `@preconcurrency`)
/// when we know empirically the call inside the closure is thread-safe
/// even though the type system can't prove it.
///
/// Threading / lifetime contract:
///   - The box is constructed on MainActor (where `Transcriber` lives),
///     captured by the detached Task created inside `TranscribeJob.run`,
///     then read once to invoke `transcribe(audioArray:)`.
///   - WhisperKit's `transcribe(audioArray:)` is internally thread-safe
///     for a given configuration — argmaxinc maintains its own queue
///     of pending transcribes per kit instance.
///   - We hold a strong reference to `kit` via the box; the kit outlives
///     the Task (it's an ivar of the MainActor `Transcriber`). No
///     dangling reference is possible.
///   - `@unchecked Sendable` only satisfies the Task.detached closure
///     signature; the actual thread safety comes from WhisperKit's
///     internal queueing.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

/// A single transcribe call's race between the real work and a deadline,
/// implemented with explicit detached tasks so it works regardless of which
/// actor `transcribe(samples:)` is called from. The MainActor-bound task
/// group from the earlier implementation could wedge if WhisperKit's
/// transcribe blocked the actor — neither the work task nor the sleep task
/// would get to run.
///
/// Uses an NSLock-guarded `completed` flag to ensure the continuation
/// resumes exactly once, no matter which side of the race wins.
private final class TranscribeJob: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var workTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Acquire the "win" flag. Returns true exactly once, even if called
    /// concurrently from work/timeout/cancel paths.
    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }

    func cancel() {
        guard claim() else { return }
        workTask?.cancel()
        timeoutTask?.cancel()
    }

    func run<T: Sendable>(
        timeout: Duration,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws
        -> T
    {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            workTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let value = try await work()
                    guard self?.claim() == true else { return }
                    self?.timeoutTask?.cancel()
                    cont.resume(returning: value)
                } catch {
                    guard self?.claim() == true else { return }
                    self?.timeoutTask?.cancel()
                    cont.resume(throwing: error)
                }
            }

            timeoutTask = Task.detached(priority: .background) { [weak self] in
                try? await Task.sleep(for: timeout)
                guard self?.claim() == true else { return }
                self?.workTask?.cancel()
                cont.resume(throwing: TranscriberError.timedOut)
            }
        }
    }
}

enum TranscriberError: LocalizedError {
    case modelNotLoaded
    case timedOut

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model isn't loaded yet."
        case .timedOut: "Transcription took too long and was cancelled."
        }
    }
}
