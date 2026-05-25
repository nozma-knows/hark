import AppKit
import SwiftUI

/// Claude auth step. Two paths: paste an ANTHROPIC_API_KEY (fast,
/// Messages API + Haiku 4.5), or use the existing Claude Code
/// subscription (OAuth via `claude setup-token`). The user picks
/// whichever they have credentials for; both paths land at the same
/// resolved state.
///
/// The API key field saves into the macOS login keychain via
/// `ClaudeAuth.setApiKey` — never logged, never echoed back to the
/// screen. The "Use my subscription" path opens Terminal and runs
/// `claude setup-token`; the resulting OAuth token lands in `~/.claude/`
/// and `ClaudeAuth.refresh()` picks it up on the next poll.
struct OnboardingClaudeStep: View {
    @Bindable var claudeAuth: ClaudeAuth

    @State private var apiKeyInput: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 18) {
            switch claudeAuth.method {
            case let .apiKey(source):
                resolvedBlock(
                    title: "Anthropic API key detected",
                    detail: "Source: \(source.rawValue). Hark uses Haiku 4.5 + prompt caching."
                )
            case let .subscription(source):
                resolvedBlock(
                    title: "Claude subscription detected",
                    detail: "Source: \(source.rawValue). Hark uses the Agent SDK path."
                )
            case .none:
                apiKeyEntry
                Divider()
                subscriptionFallback
            }

            Text("Get an API key at console.anthropic.com — pay-as-you-go, no subscription needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resolvedBlock(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Label(title, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
        )
    }

    private var apiKeyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anthropic API key")
                .font(.callout.weight(.medium))
            SecureField("sk-ant-…", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(saveApiKey)
            HStack {
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Save key", action: saveApiKey)
                    .buttonStyle(.bordered)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Stored in your macOS login Keychain. Never bundled or transmitted by Hark.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var subscriptionFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or use a Claude subscription")
                .font(.callout.weight(.medium))
            if claudeAuth.claudeBinaryPath != nil {
                Button("Generate OAuth token in Terminal") {
                    claudeAuth.runSetupToken()
                }
                .buttonStyle(.bordered)
                Text("Sign in with Anthropic in your browser; Hark picks the token up automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Link("Install Claude Code →", destination: Self.claudeCodeURL)
                Text("Then run `claude setup-token` and click Refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh") { claudeAuth.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try claudeAuth.setApiKey(trimmed)
            apiKeyInput = ""
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static let claudeCodeURL: URL = {
        // Verified URL for the Claude Code product page.
        guard let url = URL(string: "https://claude.com/code") else {
            preconditionFailure("Hard-coded URL must parse")
        }
        return url
    }()
}
