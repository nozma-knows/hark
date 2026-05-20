import SwiftUI

struct PanelRootView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Hark")
                .font(.title3.weight(.semibold))
            Text("Hold the global hotkey to dictate. The transcript and ticket draft will land here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(.regularMaterial)
    }
}

#Preview {
    PanelRootView()
        .frame(width: 560, height: 320)
}
