import AppKit
import SwiftUI

/// Searchable list of past transcripts and command outcomes.
///
/// Three actions per row: copy the displayed text, view the original
/// raw Whisper output, and re-run (only for command-kind entries —
/// re-running a dictation just re-pastes the polished text). Selection
/// state lives in the view; the store is read-only here.
struct HistoryView: View {
    @Bindable var store: HistoryStore
    /// Closure that re-issues a transcript through the original
    /// pipeline branch. Injected so the view doesn't reach into the
    /// orchestrator directly — keeps testability clean.
    let onReRun: (HistoryEntry) -> Void

    @State private var query: String = ""
    /// Currently selected row, or nil. Used to render the detail
    /// panel without re-querying the filtered list.
    @State private var selection: HistoryEntry.ID?
    /// Confirmation gate on the "Clear history" destructive action.
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .onAppear { store.load() }
        .alert("Clear history?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                store.clear()
                selection = nil
            }
        } message: {
            Text("Permanently erases \(store.entries.count) transcripts. This can't be undone.")
        }
    }

    // MARK: - Layout pieces

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(filtered.count) of \(store.entries.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Button("Clear…", role: .destructive) {
                confirmingClear = true
            }
            .buttonStyle(.borderless)
            .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No transcripts yet" : "No matches")
                .font(.title3.weight(.medium))
            Text(query.isEmpty
                ? "Hark records every dictation and command here."
                : "Try a shorter or different search term.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        HSplitView {
            // Left: list
            List(filtered, selection: $selection) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.id)
            }
            .listStyle(.inset)
            .frame(minWidth: 280, idealWidth: 320)

            // Right: detail
            if let selected = filtered.first(where: { $0.id == selection }) ?? filtered.first {
                HistoryDetail(entry: selected, onReRun: { onReRun(selected) })
                    .frame(minWidth: 320)
            } else {
                Text("Select an entry")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filtered: [HistoryEntry] {
        store.search(query)
    }
}

// MARK: - List row

private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(iconColor)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayText)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.kind.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(iconColor.opacity(0.15))
                        )
                        .foregroundStyle(iconColor)
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch entry.kind {
        case .dictate: .blue
        case .insert: .indigo
        case .command: entry.succeeded ? .green : .orange
        }
    }
}

// MARK: - Detail

private struct HistoryDetail: View {
    let entry: HistoryEntry
    let onReRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let polished = entry.polished {
                        labeledBlock("Polished", text: polished)
                    }
                    labeledBlock("Raw transcript", text: entry.transcript)
                    labeledBlock("Outcome", text: entry.summary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Spacer(minLength: 0)
            actions
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.label)
                    .font(.headline)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.kind == .command {
                Label(
                    entry.succeeded ? "Succeeded" : "Failed",
                    systemImage: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.succeeded ? .green : .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func labeledBlock(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.displayText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            if entry.kind == .command {
                Button {
                    onReRun()
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }
}
