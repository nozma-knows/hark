import SwiftUI

/// Claude auth + usage. By far the largest Settings pane because it
/// owns BOTH the API-key input flow (Keychain-backed) AND the
/// subscription-OAuth fallback affordances. Split out of SettingsView
/// so each pane lives in its own file.
struct ClaudePane: View {
    @Bindable var auth: ClaudeAuth
    @Bindable var appState: AppState

    /// Buffered user input for the API key field. Empty until the user
    /// types something; resetting on save / clear so the field never
    /// echoes a real key back to the screen.
    @State private var apiKeyInput: String = ""
    /// Surfaces a Keychain save / read failure inline instead of failing
    /// silently. Cleared on the next successful action.
    @State private var apiKeyError: String?

    var body: some View {
        Form {
            authSection
            apiKeySection
            subscriptionFallbackSection
            usageSection
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Sections

    private var authSection: some View {
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
    }

    private var apiKeySection: some View {
        Section {
            if auth.hasKeychainApiKey {
                HStack {
                    Label("API key saved in Keychain", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        apiKeyError = nil
                        try? auth.setApiKey(nil)
                        apiKeyInput = ""
                    }
                    .buttonStyle(.bordered)
                }
            }

            SecureField(
                auth.hasKeychainApiKey ? "Replace existing key…" : "sk-ant-…",
                text: $apiKeyInput
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            HStack {
                if let apiKeyError {
                    Text(apiKeyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Save") {
                    saveApiKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Anthropic API key")
        } footer: {
            Text(
                """
                Stored in your macOS login keychain. When set, Hark uses \
                the Messages API (Haiku 4.5 + prompt caching) — faster \
                and unaffected by Claude Code's local settings.json. \
                Get a key at console.anthropic.com.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var subscriptionFallbackSection: some View {
        // Only surface the subscription path when nothing's configured yet —
        // most users land on the API-key flow first, and the fallback
        // affordance is noise once they have working auth.
        if auth.method == .none {
            Section("Or use a Claude subscription") {
                if auth.claudeBinaryPath != nil {
                    Button("Generate OAuth token in Terminal") {
                        auth.runSetupToken()
                    }
                    .buttonStyle(.bordered)
                    Text(
                        """
                        Sign in with Anthropic in your browser; the token \
                        lands in ~/.claude/, Hark picks it up on Refresh.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Link("Install Claude Code", destination: claudeCodeURL)
                        .controlSize(.regular)
                    Text("Then run `claude setup-token` and Refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageSection: some View {
        Section {
            UsageRow(label: "Requests", value: "\(appState.claudeUsage.requestCount)")
            UsageRow(label: "Input tokens", value: formatted(appState.claudeUsage.inputTokens))
            UsageRow(label: "Output tokens", value: formatted(appState.claudeUsage.outputTokens))
            if appState.claudeUsage.cacheReadTokens > 0 {
                UsageRow(label: "Cache read", value: formatted(appState.claudeUsage.cacheReadTokens))
            }
            if appState.claudeUsage.cacheCreationTokens > 0 {
                UsageRow(label: "Cache write", value: formatted(appState.claudeUsage.cacheCreationTokens))
            }
            UsageRow(label: "Total tokens", value: formatted(appState.claudeUsage.totalTokens))
            if let lastUsed = appState.claudeUsage.lastUsedAt {
                UsageRow(label: "Last used", value: lastUsed.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Cumulative across launches; polish + command calls only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Persist the typed key, reset the field, and surface any Keychain
    /// failure inline. AppDelegate's `onCredentialsChanged` callback
    /// restarts the sidecar so the next request uses the new auth path.
    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try auth.setApiKey(trimmed)
            apiKeyError = nil
            apiKeyInput = ""
        } catch {
            apiKeyError = error.localizedDescription
        }
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
        case .none: "Hark needs a Claude credential to polish transcripts and run voice commands."
        }
    }

    private var claudeCodeURL: URL {
        // Verified link to Claude Code product page.
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://claude.com/code")!
    }
}

/// Single-row helper used by the Usage section. Lives next to the
/// only consumer; if a future pane needs the same shape we can lift
/// it into a shared utilities file then.
private struct UsageRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}
