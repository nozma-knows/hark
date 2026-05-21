import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let hotkey: HotkeyManager
    let transcriber: Transcriber
    let claudeAuth: ClaudeAuth

    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyPane(hotkey: hotkey)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            LinearPane()
                .tabItem { Label("Linear", systemImage: "rectangle.stack") }
            ClaudePane(auth: claudeAuth)
                .tabItem { Label("Claude", systemImage: "sparkles") }
            ModelsPane(transcriber: transcriber)
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    var body: some View {
        SettingsPlaceholder(
            systemImage: "gearshape",
            title: "General",
            detail: "Launch at login, panel position, default repo, and model preferences."
        )
    }
}

private struct HotkeyPane: View {
    @Bindable var hotkey: HotkeyManager

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Global shortcut:", name: .summonPanel)
            } footer: {
                Text("Requires Accessibility permission. Default is ⌃⌥ Space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mode", selection: $hotkey.mode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(hotkey.mode.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct LinearPane: View {
    var body: some View {
        SettingsPlaceholder(
            systemImage: "rectangle.stack",
            title: "Linear",
            detail: "Personal API key, default team/project, and workflow state."
        )
    }
}

private struct ClaudePane: View {
    @Bindable var auth: ClaudeAuth

    var body: some View {
        Form {
            Section("Auth") {
                HStack(spacing: 14) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 28))
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.method.shortLabel)
                            .font(.headline)
                        Text(sourceDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { auth.refresh() }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }

            if !auth.method.isResolved {
                Section("Get set up") {
                    if auth.claudeBinaryPath != nil {
                        Button("Generate OAuth token in Terminal") {
                            auth.runSetupToken()
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Sign in with Anthropic in your browser; the token lands in ~/.claude/, Hark picks it up.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Link("Install Claude Code", destination: claudeCodeURL)
                            .controlSize(.regular)
                        Text(
                            "Or export ANTHROPIC_API_KEY in your shell, then Refresh. Hark never stores tokens itself."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statusIcon: String {
        switch auth.method {
        case .subscription: "checkmark.seal.fill"
        case .apiKey: "key.fill"
        case .none: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch auth.method {
        case .subscription, .apiKey: .green
        case .none: .orange
        }
    }

    private var sourceDetail: String {
        switch auth.method {
        case let .subscription(source): "Source: \(source.rawValue)"
        case let .apiKey(source): "Source: \(source.rawValue)"
        case .none: "Hark needs a Claude credential to plan tickets."
        }
    }

    private var claudeCodeURL: URL {
        // Verified link to Claude Code product page.
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://claude.com/code")!
    }
}

private struct ModelsPane: View {
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

// MARK: - Placeholder shell

private struct SettingsPlaceholder: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    SettingsView(
        hotkey: HotkeyManager(),
        transcriber: Transcriber(),
        claudeAuth: ClaudeAuth()
    )
}
