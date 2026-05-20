import SwiftUI

@main
struct HarkApp: App {
    var body: some Scene {
        MenuBarExtra {
            HarkMenuContent()
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Hark")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct HarkMenuContent: View {
    var body: some View {
        Text("Hark")
            .font(.headline)
        Divider()
        Button("Quit Hark") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
