import Foundation

/// The on-device Whisper variants Hark ships against. English-only (`.en`)
/// builds are smaller, faster, and more accurate for dictation than the
/// multilingual versions, so we default to them.
enum WhisperModel: String, CaseIterable, Identifiable, Codable {
    case tinyEn = "openai_whisper-tiny.en"
    case baseEn = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en"
    case mediumEn = "openai_whisper-medium.en"

    var id: Self { self }

    /// The exact variant string WhisperKit recognises. We pass the rawValue
    /// to `WhisperKit.download(variant:)` and the matching `WhisperKitConfig`.
    var variant: String { rawValue }

    var shortName: String {
        switch self {
        case .tinyEn: "Tiny"
        case .baseEn: "Base"
        case .smallEn: "Small"
        case .mediumEn: "Medium"
        }
    }

    /// Approximate compressed download size (bytes).
    var approximateBytes: Int64 {
        switch self {
        case .tinyEn: 75 * 1024 * 1024
        case .baseEn: 150 * 1024 * 1024
        case .smallEn: 480 * 1024 * 1024
        case .mediumEn: 1500 * 1024 * 1024
        }
    }

    var blurb: String {
        switch self {
        case .tinyEn: "Fastest cold load (~5s). Good for voice commands and short dictation."
        case .baseEn: "Quick and serviceable for routine dictation."
        case .smallEn: "Best balance of accuracy and speed. Slower cold load (~30-60s)."
        case .mediumEn: "Best accuracy; slower download and inference."
        }
    }

    /// True for the install-default model — labels it in the UI so users
    /// know which one Hark picked for them. Tracks `Self.default` so a
    /// future default change updates the badge automatically.
    var recommended: Bool {
        self == Self.default
    }

    /// Default model the app picks on first run.
    ///
    /// `tinyEn` is the default because cold-load time dominates first-use
    /// UX: `smallEn` takes 30-150s on a fresh machine (CoreML compilation
    /// of the larger AudioEncoder/TextDecoder), `tinyEn` is under 10s.
    /// Users who want better accuracy can switch to `smallEn` from
    /// Settings → Models — but they shouldn't be forced to wait two
    /// minutes on their first launch to find that out.
    static let `default`: WhisperModel = .tinyEn
}
