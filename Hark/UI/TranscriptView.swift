import AppKit
import SwiftUI

struct TranscriptView: View {
    let text: String
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .foregroundStyle(.secondary)
                Text("Transcript")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                }
                Button("Dismiss") {
                    appState.transcript = nil
                    appState.isPanelVisible = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

#Preview {
    TranscriptView(
        text: "Add a Linear backend for the ticket creation flow and wire up Claude Agent SDK as a Bun sidecar.",
        appState: AppState()
    )
    .frame(width: 560, height: 320)
}
