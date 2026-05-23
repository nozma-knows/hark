import SwiftUI

/// Whisper model picker — list every model in the catalog, show disk
/// usage, current load state, and a Use/Download button. Selecting
/// switches the active model (and triggers a download if missing).
struct ModelsPane: View {
    @Bindable var transcriber: Transcriber

    var body: some View {
        Form {
            Section {
                ForEach(WhisperModel.allCases) { model in
                    ModelRow(model: model, transcriber: transcriber)
                }
            } footer: {
                Text("Models live in ~/Library/Application Support/Hark/Models. Switching loads the chosen model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// One row per model. Lives in the same file as its sole consumer
/// because it's tightly coupled to ModelsPane's layout assumptions —
/// hoisting it elsewhere would just add indirection.
private struct ModelRow: View {
    let model: WhisperModel
    @Bindable var transcriber: Transcriber

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.shortName)
                        .font(.headline)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if model.recommended {
                        Text("Recommended")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(.tint.opacity(0.18))
                            )
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    Text(formattedSize)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(model.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                statusLine
            }
            actionView
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusLine: some View {
        switch transcriber.state {
        case let .downloading(downloading, progress) where downloading == model:
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case let .loading(loading) where loading == model:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .ready(ready) where ready == model:
            Text("Loaded")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message) where transcriber.selectedModel == model:
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var actionView: some View {
        if isBusy {
            EmptyView()
        } else if transcriber.isDownloaded(model) {
            if isSelected {
                Text("In use")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") {
                    Task { await transcriber.select(model) }
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button("Download") {
                Task { await transcriber.select(model) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var isSelected: Bool {
        transcriber.selectedModel == model
    }

    private var isBusy: Bool {
        switch transcriber.state {
        case let .downloading(m, _), let .loading(m), let .transcribing(m):
            m == model
        default:
            false
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file)
    }
}
