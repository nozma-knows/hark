import SwiftUI

/// Custom voice commands.
///
/// One row per user-defined alias; each alias is `phrase` + one or more
/// shell `commands` run in order. Adding an alias drops it into the
/// store, which atomically writes the aliases.json file the sidecar
/// reads on the next dispatch (1s mtime cache).
struct AliasesPane: View {
    @Bindable var store: AliasStore

    @State private var draftPhrase: String = ""
    @State private var draftCommands: String = ""
    @State private var draftError: String?

    /// Alias currently expanded for editing in the list. Nil when no
    /// row is open; setting it collapses any other open row.
    @State private var editing: UUID?

    var body: some View {
        Form {
            existingSection
            newSection
            helpSection
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Existing aliases

    private var existingSection: some View {
        Section {
            if store.aliases.isEmpty {
                Text("No custom commands yet. Add one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.aliases) { alias in
                    AliasRow(
                        alias: alias,
                        isExpanded: editing == alias.id,
                        onToggleExpand: {
                            editing = editing == alias.id ? nil : alias.id
                        },
                        onSave: { updated in
                            if store.update(updated) {
                                editing = nil
                            }
                        },
                        onDelete: {
                            store.delete(id: alias.id)
                            editing = nil
                        }
                    )
                }
            }
        } header: {
            Text("Custom commands")
        }
    }

    // MARK: - New alias

    private var newSection: some View {
        Section {
            TextField(
                "Trigger phrase (e.g. \"standup\")",
                text: $draftPhrase
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            TextEditor(text: $draftCommands)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                if let draftError {
                    Text(draftError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Add") {
                    addAlias()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
        } header: {
            Text("Add a new command")
        } footer: {
            Text(
                """
                Each line is one shell command. Hark runs them in order, \
                stopping at the first failure. Phrases match exactly after \
                normalization — say the phrase and nothing else.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var helpSection: some View {
        Section {
            Text(
                """
                Examples
                  • Phrase: standup → open -a Zoom + open -a 'Slack'
                  • Phrase: focus mode → osascript -e 'tell …' + open shortcut
                """
            )
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Add helpers

    private var canAdd: Bool {
        let phrase = draftPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = parsedDraftCommands()
        return !phrase.isEmpty && !commands.isEmpty
    }

    private func addAlias() {
        let commands = parsedDraftCommands()
        guard store.add(phrase: draftPhrase, commands: commands) != nil else {
            draftError = "Couldn't add — make sure both the phrase and at least one command are filled in."
            return
        }
        draftPhrase = ""
        draftCommands = ""
        draftError = nil
    }

    private func parsedDraftCommands() -> [String] {
        draftCommands
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One row in the list. Collapsed shows the phrase + command count;
/// expanded reveals the editable fields with Save / Delete actions.
private struct AliasRow: View {
    let alias: Alias
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSave: (Alias) -> Void
    let onDelete: () -> Void

    @State private var draftPhrase: String = ""
    @State private var draftCommands: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(alias.phrase)
                        .font(.headline)
                    Text(commandsPreview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            if isExpanded {
                Divider()
                TextField("Trigger phrase", text: $draftPhrase)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                TextEditor(text: $draftCommands)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    )

                HStack {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Save") {
                        let commands = draftCommands
                            .split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave(Alias(id: alias.id, phrase: draftPhrase, commands: commands))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { syncDrafts() }
        .onChange(of: isExpanded) { _, _ in syncDrafts() }
        .onChange(of: alias) { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        draftPhrase = alias.phrase
        draftCommands = alias.commands.joined(separator: "\n")
    }

    private var commandsPreview: String {
        switch alias.commands.count {
        case 0: ""
        case 1: alias.commands[0]
        default: "\(alias.commands.count) commands"
        }
    }
}
