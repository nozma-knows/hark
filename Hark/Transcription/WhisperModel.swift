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
        case .tinyEn: "Smallest, fastest. Acceptable for short commands."
        case .baseEn: "Quick and serviceable for routine dictation."
        case .smallEn: "Recommended balance of accuracy and speed."
        case .mediumEn: "Best accuracy; slower download and inference."
        }
    }

    var recommended: Bool {
        self == .smallEn
    }

    /// Default model the app picks on first run.
    static let `default`: WhisperModel = .smallEn
}
