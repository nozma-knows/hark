import SwiftUI

/// Inline Anthropic API-key entry shown beneath the Claude auth card
/// during onboarding, so users can paste a key without detouring through
/// Settings afterward. Mirrors ClaudePane's Keychain-backed save flow:
/// the field buffers user input, never echoes a stored key back, and
/// surfaces Keychain failures inline. Saving fires `setApiKey`, which
/// persists to the login keychain and restarts the sidecar via
/// `onCredentialsChanged` so the new auth path takes effect immediately.
struct OnboardingApiKeyField: View {
    @Bindable var claudeAuth: ClaudeAuth

    /// Buffered user input. Empty until the user types; reset on save /
    /// clear so the field never echoes a real key back to the screen.
    @State private var apiKeyInput: String = ""
    /// Surfaces a Keychain save failure inline instead of failing
    /// silently. Cleared on the next successful action.
    @State private var apiKeyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if claudeAuth.hasKeychainApiKey {
                HStack {
                    Label("API key saved in Keychain", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        apiKeyError = nil
                        try? claudeAuth.setApiKey(nil)
                        apiKeyInput = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                SecureField(
                    claudeAuth.hasKeychainApiKey ? "Replace existing key…" : "Paste ANTHROPIC_API_KEY (sk-ant-…)",
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                Button("Save") {
                    saveApiKey()
                }
                .buttonStyle(.bordered)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let apiKeyError {
                Text(apiKeyError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("Stored in your macOS login keychain. Get a key at console.anthropic.com.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    /// Persist the typed key, reset the field, and surface any Keychain
    /// failure inline. Mirrors ClaudePane.saveApiKey so onboarding and
    /// Settings behave identically.
    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try claudeAuth.setApiKey(trimmed)
            apiKeyError = nil
            apiKeyInput = ""
        } catch {
            apiKeyError = error.localizedDescription
        }
    }
}

#Preview {
    OnboardingApiKeyField(claudeAuth: ClaudeAuth())
        .padding()
        .frame(width: 460)
}
