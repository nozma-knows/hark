import AppKit
import SwiftUI

/// Diagnostics surface — log file location, crash report folder, the
/// kind of "where do I look when something breaks" plumbing a support
/// engineer asks about first. Read-only; the actions just reveal the
/// files in Finder.
///
/// Extracted from SettingsView so the parent stays a TabView shell;
/// every other pane lives in its own file too.
struct GeneralPane: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log file")
                            .font(.callout.weight(.medium))
                        Text(FileLogger.shared.logFileURL.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            FileLogger.shared.currentLogs()
                        )
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Crash reports")
                            .font(.callout.weight(.medium))
                        Text(FileLogger.shared.logDirectory.appending(path: "crashes").path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Open Folder") {
                        let crashDir = FileLogger.shared.logDirectory.appending(path: "crashes")
                        try? FileManager.default.createDirectory(
                            at: crashDir,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(crashDir)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Hark mirrors important events to a local log file. Attach to support emails when something breaks."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
