import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Settings")
                .font(.title3.weight(.semibold))
            Text("Hotkey, transcription model, Linear, and Claude\nauth land here in upcoming milestones.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 460, height: 260)
        .padding()
    }
}

#Preview {
    SettingsView()
}
