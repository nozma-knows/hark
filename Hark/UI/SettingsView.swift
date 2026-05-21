import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyPane()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            LinearPane()
                .tabItem { Label("Linear", systemImage: "rectangle.stack") }
            ClaudePane()
                .tabItem { Label("Claude", systemImage: "sparkles") }
            ModelsPane()
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 520, height: 360)
    }
}

// MARK: - Panes (placeholders; populated in later PRs)

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
    var body: some View {
        SettingsPlaceholder(
            systemImage: "keyboard",
            title: "Hotkey",
            detail: "Choose the global shortcut and whether it's hold-to-talk or toggle."
        )
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
    var body: some View {
        SettingsPlaceholder(
            systemImage: "sparkles",
            title: "Claude",
            detail: "Detected auth method (subscription OAuth or your own ANTHROPIC_API_KEY)."
        )
    }
}

private struct ModelsPane: View {
    var body: some View {
        SettingsPlaceholder(
            systemImage: "cpu",
            title: "Models",
            detail: "Download and select an on-device WhisperKit model."
        )
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
    SettingsView()
}
