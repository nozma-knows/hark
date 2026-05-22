import SwiftUI

// MARK: - Idle (visible pill grows from the center, inside a fixed hit-area)

struct IdlePillView: View {
    let actions: PanelActions
    @Bindable var recorder: AudioRecorder
    @State private var isHovered = false
    @State private var showHelp = false

    private static let collapsedWidth: CGFloat = 40
    private static let collapsedHeight: CGFloat = 3
    private static let expandedWidth: CGFloat = 156
    private static let expandedHeight: CGFloat = 24

    private var isRecording: Bool { recorder.state == .recording }

    /// Outer hit-test frame is constant (matches the expanded pill bounds),
    /// so the pill's visual center never shifts when growing/collapsing.
    /// The visible capsule is centered inside this frame, anchored at the
    /// frame's center — never the bottom. Without this, the pill grows
    /// upward off its bottom edge and the cursor (which triggered hover at
    /// the center of the small pill) ends up at the bottom of the expanded
    /// pill, which feels like the pill is "running away" from the cursor.
    private var pillWidth: CGFloat { isHovered ? Self.expandedWidth : Self.collapsedWidth }
    private var pillHeight: CGFloat { isHovered ? Self.expandedHeight : Self.collapsedHeight }

    var body: some View {
        ZStack {
            // Background fades in
            Capsule(style: .continuous)
                .fill(.black.opacity(isHovered ? 0.82 : 0))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(isHovered ? 0.1 : 0), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: 10, y: 3)

            // Outline fades out — the only thing visible at rest.
            Capsule(style: .continuous)
                .stroke(.white.opacity(isHovered ? 0 : 0.35), lineWidth: 1)

            // Hover content: record button (with a chevron menu for the two
            // non-default modes) on the left, settings + help on the right.
            HStack(spacing: 0) {
                RecordMenu(actions: actions, isRecording: isRecording)
                Spacer(minLength: 6)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Shortcuts")
                .popover(isPresented: $showHelp, arrowEdge: .top) {
                    ShortcutsPopover()
                }
            }
            .padding(.horizontal, 8)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(width: pillWidth, height: pillHeight)
        // The outer frame stays constant — visible pill is centered inside it
        // and grows from the center, so its visual position never shifts.
        .frame(width: Self.expandedWidth, height: Self.expandedHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isHovered)
    }
}

/// Record button + chevron menu. The bare button toggles recording in the
/// default `.dictate` mode (transcribe-only). The chevron's menu offers the
/// two non-default modes — `.command` (Execute) and `.insert` (Fill input)
/// — which also start recording when picked. A second click on the record
/// button stops any in-progress recording regardless of which trigger
/// started it.
private struct RecordMenu: View {
    let actions: PanelActions
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                actions.toggleRecording(.dictate)
            } label: {
                Image(systemName: isRecording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isRecording ? .white : .red)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Stop" : "Record")

            // While recording, the chevron is disabled — the user must stop
            // the current recording before picking a different mode.
            Menu {
                Button("Execute") { actions.toggleRecording(.command) }
                Button("Fill input") { actions.toggleRecording(.insert) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(isRecording)
            .opacity(isRecording ? 0.4 : 1)
            .fixedSize()
        }
        .background(Capsule(style: .continuous).fill(.white.opacity(0.12)))
        .clipShape(Capsule(style: .continuous))
    }
}

/// Help popover content — the canonical shortcut reference shown next to
/// the gear icon. Renders identically to the in-app docs so users learn
/// the keyboard equivalents while clicking around.
private struct ShortcutsPopover: View {
    private struct Row: Identifiable {
        let id: String
        let shortcut: String
        let name: String
        let description: String
    }

    private let rows: [Row] = [
        Row(
            id: "fn",
            shortcut: "Fn",
            name: "Dictate",
            description: "Push-to-talk: transcript appears in the pill."
        ),
        Row(
            id: "ctrl-fn",
            shortcut: "⌃Fn",
            name: "Fill input",
            description: "Polished transcript pasted at the cursor."
        ),
        Row(
            id: "shift-fn",
            shortcut: "⇧Fn",
            name: "Execute",
            description: "Voice command — run via Claude Agent SDK."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.shortcut)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.secondary.opacity(0.18)))
                            .frame(minWidth: 36, alignment: .center)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(row.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
