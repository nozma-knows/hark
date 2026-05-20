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

    /// Whether the given model's files are already on disk.
    func isDownloaded(_ model: WhisperModel) -> Bool {
        let dir = Self.modelsDirectory.appending(path: model.variant, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: dir.path)
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

    /// Transcribe 16 kHz mono Float32 samples to a single string. Joins
    /// segments with a space. Throws if no model is loaded.
    func transcribe(samples: [Float]) async throws -> String {
        guard let kit = whisperKit, let model = loadedModel else {
            throw TranscriberError.modelNotLoaded
        }
        state = .transcribing(model)
        defer { state = .ready(model) }

        let results = try await kit.transcribe(audioArray: samples)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case modelNotLoaded
}
