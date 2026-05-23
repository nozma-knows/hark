import SwiftUI

/// Settings window scene. Pure orchestration — each pane lives in its
/// own file under `Hark/UI/Settings/` so this file stays a quick map
/// of "which tabs does Hark have" without dragging in form fields,
/// button handlers, or auth-flow state.
///
/// The TabView width/height is the canonical Hark settings window size;
/// every pane is laid out against it.
struct SettingsView: View {
    let hotkey: HotkeyManager
    let transcriber: Transcriber
    let claudeAuth: ClaudeAuth
    let appState: AppState
    /// Resets the sidecar's rolling conversation history. Closure-injected
    /// so the Settings UI doesn't need direct access to `AgentSidecar`;
    /// the production binding lives in HarkApp.
    let onResetConversation: () -> Void

    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeyPane(hotkey: hotkey)
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            ClaudePane(
                auth: claudeAuth,
                appState: appState,
                onResetConversation: onResetConversation
            )
            .tabItem { Label("Claude", systemImage: "sparkles") }
            ModelsPane(transcriber: transcriber)
                .tabItem { Label("Models", systemImage: "cpu") }
        }
        .frame(width: 560, height: 460)
    }
}

#Preview {
    SettingsView(
        hotkey: HotkeyManager(),
        transcriber: Transcriber(),
        claudeAuth: ClaudeAuth(),
        appState: AppState(),
        onResetConversation: {}
    )
}
