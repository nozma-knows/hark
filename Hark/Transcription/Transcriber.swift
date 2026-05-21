import Foundation
import Observation
import OSLog

// WhisperKit isn't marked Sendable yet; @preconcurrency suppresses the actor
// crossing warnings. We only ever touch the instance from this @MainActor
// class, so the runtime semantics are correct.
@preconcurrency import WhisperKit

/// Manages WhisperKit's lifecycle + the live `AudioStreamTranscriber` so the
/// panel sees the transcript evolve as the user speaks. Owns its own
/// microphone capture (via WhisperKit's `AudioProcessor`) — there is no
/// separate AudioRecorder in the live path.
///
/// State machine: `.unloaded` → `.downloading(progress)` → `.loading` →
/// `.ready` → `.recording` → back to `.ready` (or `.failed`).
@MainActor
@Observable
final class Transcriber {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Transcriber")
    private static let selectedModelDefaultsKey = "co.milbo.hark.selectedModel"

    enum State: Equatable {
        case unloaded
        case downloading(WhisperModel, progress: Double)
        case loading(WhisperModel)
        case ready(WhisperModel)
        case recording(WhisperModel)
        case failed(String)
    }

    private(set) var state: State = .unloaded

    /// Model the user has chosen. Persisted across launches. Mutate via
    /// `select(_:)` to also trigger download/load.
    private(set) var selectedModel: WhisperModel = {
        let raw = UserDefaults.standard.string(forKey: Transcriber.selectedModelDefaultsKey)
        return raw.flatMap(WhisperModel.init(rawValue:)) ?? .default
    }()

    /// Live, evolving transcript text while `state == .recording`. Cleared on
    /// each new recording. Reflects WhisperKit's most recent decoded text.
    private(set) var liveText: String = ""

    /// Text from confirmed segments only (useful for showing a settled head
    /// vs. an unsettled tail). Currently unused by the UI but cheap to keep.
    private(set) var confirmedText: String = ""

    /// Recent buffer energy (one float per ~10ms) for waveform rendering.
    private(set) var bufferEnergy: [Float] = []

    /// Where WhisperKit caches model weights. The actual layout under here is
    /// `<base>/models/argmaxinc/whisperkit-coreml/<variant>/…` — that's the
    /// nested path WhisperKit's HuggingFace downloader writes to.
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
    private var streamTranscriber: AudioStreamTranscriber?

    // MARK: - Disk

    /// Whether the given model's compiled CoreML files are on disk.
    func isDownloaded(_ model: WhisperModel) -> Bool {
        let encoder = Self.modelsDirectory
            .appending(path: "models/argmaxinc/whisperkit-coreml/\(model.variant)/AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    // MARK: - Model lifecycle

    /// Persist the user's choice and load it (downloading first if needed).
    func select(_ model: WhisperModel) async {
        if selectedModel != model {
            selectedModel = model
            UserDefaults.standard.set(model.rawValue, forKey: Self.selectedModelDefaultsKey)
            // Tear down the stream transcriber so the next start rebuilds it
            // against the new WhisperKit instance.
            await streamTranscriber?.stopStreamTranscription()
            streamTranscriber = nil
            whisperKit = nil
            loadedModel = nil
        }
        await loadIfNeeded(model)
    }

    /// Bootstrap on app launch — loads the previously selected model in the
    /// background so the first dictation doesn't pay the load cost.
    func bootstrap() {
        let model = selectedModel
        Task { await loadIfNeeded(model) }
    }

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
            let config = WhisperKitConfig(
                model: model.variant,
                downloadBase: Self.modelsDirectory,
                verbose: false,
                logLevel: .error
            )
            let kit = try await WhisperKit(config)
            whisperKit = kit
            loadedModel = model
            state = .ready(model)
            Self.logger.info("Loaded model \(model.variant, privacy: .public)")
        } catch {
            let message = String(describing: error)
            Self.logger.error("Model load failed: \(message, privacy: .public)")
            state = .failed(message)
        }
    }

    // MARK: - Streaming

    /// Begin live capture + streaming transcription. The UI binds to
    /// `liveText` / `bufferEnergy` for real-time feedback. Throws if a model
    /// isn't loaded yet.
    func startStream() async throws {
        guard let kit = whisperKit, let model = loadedModel else {
            throw TranscriberError.modelNotLoaded
        }
        liveText = ""
        confirmedText = ""
        bufferEnergy.removeAll(keepingCapacity: true)

        let stream: AudioStreamTranscriber
        if let existing = streamTranscriber {
            stream = existing
        } else {
            guard
                let built = Self.makeStreamTranscriber(kit: kit, onState: { [weak self] newState in
                    Task { @MainActor [weak self] in
                        self?.applyStreamState(newState)
                    }
                }) else
            {
                throw TranscriberError.modelNotLoaded
            }
            streamTranscriber = built
            stream = built
        }
        state = .recording(model)
        try await stream.startStreamTranscription()
    }

    /// Stop capture + streaming. Returns the final concatenated transcript
    /// (confirmed segments + the trailing live text). Empty if Whisper
    /// produced nothing.
    @discardableResult
    func stopStream() async -> String {
        await streamTranscriber?.stopStreamTranscription()
        let final = Self.combine(confirmed: confirmedText, live: liveText)
        if let model = loadedModel { state = .ready(model) }
        return final
    }

    // MARK: - Private

    private func applyStreamState(_ newState: AudioStreamTranscriber.State) {
        bufferEnergy = newState.bufferEnergy
        liveText = newState.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        confirmedText = newState.confirmedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func combine(confirmed: String, live: String) -> String {
        var pieces: [String] = []
        if !confirmed.isEmpty { pieces.append(confirmed) }
        if !live.isEmpty, live != confirmed { pieces.append(live) }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeStreamTranscriber(
        kit: WhisperKit,
        onState: @escaping @Sendable (AudioStreamTranscriber.State) -> Void
    )
        -> AudioStreamTranscriber?
    {
        guard let tokenizer = kit.tokenizer else { return nil }
        return AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: DecodingOptions(language: "en", usePrefillPrompt: false),
            useVAD: false,
            stateChangeCallback: { _, new in onState(new) }
        )
    }
}

enum TranscriberError: Error {
    case modelNotLoaded
}
