import AppKit
import SwiftUI

/// Diagnostics + opt-in telemetry surface. Read-only paths (log file +
/// crash folder) plus the user-configurable HTTPS endpoint for crash
/// uploads.
///
/// Extracted from SettingsView so the parent stays a TabView shell;
/// every other pane lives in its own file too.
struct GeneralPane: View {
    let pillPosition: PillPositionSettings

    /// Buffered user input for the crash-upload endpoint. Loaded from
    /// UserDefaults on first render; pushed back via "Save."
    @State private var endpointInput: String = CrashUploadPreferences.endpointString ?? ""
    /// Shows a "Saved" pill for ~2s after the user persists the value
    /// so the click has visible feedback.
    @State private var savedConfirmed = false
    /// Surfaced inline when the user pastes a non-HTTPS or malformed URL.
    @State private var endpointError: String?

    var body: some View {
        Form {
            pillPositionSection
            diagnosticsSection
            crashUploadsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Pill position

    private var pillPositionSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current position")
                        .font(.callout.weight(.medium))
                    Text(pillPosition.model.anchor.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to center") {
                    pillPosition.resetActive()
                }
                if pillPosition.hasAnyStoredAnchor() {
                    Button("Reset all displays", role: .destructive) {
                        pillPosition.resetAll()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Pill position")
        } footer: {
            Text(
                """
                Drag the pill along the bottom of the screen to move it. \
                Hold ⌘ to drag from anywhere on the pill. \
                Position is remembered per display.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private var diagnosticsSection: some View {
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

    private var crashUploadsSection: some View {
        Section {
            TextField(
                "https://your-collector.example.com/hark",
                text: $endpointInput
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .onSubmit { saveEndpoint() }

            HStack(spacing: 8) {
                if let endpointError {
                    Text(endpointError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if savedConfirmed {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else if CrashUploadPreferences.endpointString != nil {
                    Label("Uploads enabled", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Text("Disabled — crashes stay local")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if CrashUploadPreferences.endpointString != nil {
                    Button("Disable", role: .destructive) {
                        CrashUploadPreferences.setEndpoint(nil)
                        CrashReporter.sink = nil
                        endpointInput = ""
                        endpointError = nil
                        savedConfirmed = false
                    }
                    .buttonStyle(.bordered)
                }
                Button("Save") {
                    saveEndpoint()
                }
                .buttonStyle(.borderedProminent)
                .disabled(endpointInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Crash uploads")
        } footer: {
            Text(
                """
                Optional. Post the crash payload (signal, stack frames, \
                app version) to an HTTPS endpoint. No transcripts, audio, \
                or keychain contents are ever included. Leave blank to \
                keep crashes local-only.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// Validate + persist the endpoint, rewire CrashReporter.sink, and
    /// briefly flash a "Saved" confirmation. Refuses non-HTTPS URLs so
    /// crash data can't accidentally go out in plaintext.
    private func saveEndpoint() {
        let trimmed = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed) else {
            endpointError = "Couldn't parse that as a URL."
            return
        }
        guard url.scheme == "https" else {
            endpointError = "Must be an https:// URL — http would send crashes in plaintext."
            return
        }
        CrashUploadPreferences.setEndpoint(trimmed)
        CrashReporter.sink = HttpCrashSink(endpoint: url)
        endpointError = nil
        savedConfirmed = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedConfirmed = false
        }
    }
}
