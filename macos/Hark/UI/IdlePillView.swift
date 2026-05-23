import SwiftUI

// MARK: - Idle (visible pill grows from the center, inside a fixed hit-area)

struct IdlePillView: View {
    let actions: PanelActions
    @Bindable var recorder: AudioRecorder
    @State private var pillHovered = false
    @State private var helpHovered = false
    @State private var popoverHovered = false
    /// True when the user explicitly clicks the `?` to pin the popover. While
    /// pinned, hover changes never dismiss it; only an explicit unpin click
    /// (or moving the cursor off both the pill and the popover) closes it.
    @State private var helpPinned = false
    @State private var helpShown = false
    /// Latched true when the user clicks to UNPIN. Suppresses the hover-open
    /// behavior until the cursor actually leaves the ? button, so a click-to-
    /// close doesn't immediately re-open the popover (cursor is still on the
    /// button after the click, which would otherwise re-trigger helpHovered).
    @State private var hoverSuppressed = false
    @State private var dismissTask: Task<Void, Never>?

    private static let collapsedWidth: CGFloat = 40
    private static let collapsedHeight: CGFloat = 3
    private static let expandedWidth: CGFloat = 156
    private static let expandedHeight: CGFloat = 24
    /// Brief grace period when the cursor leaves the pill / help button /
    /// popover. Lets the user move between them without dropping the open
    /// state in the gap.
    private static let dismissDelay: Duration = .milliseconds(180)

    private var isRecording: Bool { recorder.state == .recording }

    /// True while any of the pill / help button / popover is hovered, OR the
    /// popover is pinned open by an explicit click. This drives both the
    /// "expanded" visual state and the "keep popover open" logic — a single
    /// derived flag means the pill stays expanded for as long as the popover
    /// is shown, even when the cursor has moved off the small ? button onto
    /// the popover content.
    private var isEngaged: Bool {
        pillHovered || helpHovered || popoverHovered || helpPinned || helpShown
    }

    /// Outer hit-test frame is constant (matches the expanded pill bounds),
    /// so the pill's visual center never shifts when growing/collapsing.
    /// The visible capsule is centered inside this frame, anchored at the
    /// frame's center — never the bottom. Without this, the pill grows
    /// upward off its bottom edge and the cursor (which triggered hover at
    /// the center of the small pill) ends up at the bottom of the expanded
    /// pill, which feels like the pill is "running away" from the cursor.
    private var pillWidth: CGFloat { isEngaged ? Self.expandedWidth : Self.collapsedWidth }
    private var pillHeight: CGFloat { isEngaged ? Self.expandedHeight : Self.collapsedHeight }

    var body: some View {
        ZStack {
            // Background fades in
            Capsule(style: .continuous)
                .fill(.black.opacity(isEngaged ? 0.82 : 0))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(isEngaged ? 0.1 : 0), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(isEngaged ? 0.45 : 0), radius: 10, y: 3)

            // Outline fades out — the only thing visible at rest.
            Capsule(style: .continuous)
                .stroke(.white.opacity(isEngaged ? 0 : 0.35), lineWidth: 1)

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
                    if helpPinned {
                        // Unpin: also dismiss the popover and suppress hover-
                        // open until the cursor leaves the button. Without
                        // the suppression flag, helpHovered would still be
                        // true and refreshHelpState() would immediately
                        // reopen the popover on the same click.
                        helpPinned = false
                        helpHovered = false
                        hoverSuppressed = true
                        dismissTask?.cancel()
                        helpShown = false
                    } else {
                        helpPinned = true
                        dismissTask?.cancel()
                        helpShown = true
                    }
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(helpPinned ? "Hide shortcuts" : "Shortcuts")
                .onHover { hovering in
                    if hovering {
                        // Ignore the immediate re-hover after a click-to-
                        // unpin; only un-suppress when the cursor genuinely
                        // leaves and comes back.
                        guard !hoverSuppressed else { return }
                        helpHovered = true
                    } else {
                        helpHovered = false
                        hoverSuppressed = false
                    }
                    refreshHelpState()
                }
                .popover(isPresented: $helpShown, arrowEdge: .top) {
                    ShortcutsPopover()
                        .onHover { hovering in
                            popoverHovered = hovering
                            refreshHelpState()
                        }
                }
            }
            .padding(.horizontal, 8)
            .opacity(isEngaged ? 1 : 0)
            .allowsHitTesting(isEngaged)
        }
        .frame(width: pillWidth, height: pillHeight)
        // The outer frame stays constant — visible pill is centered inside it
        // and grows from the center, so its visual position never shifts.
        .frame(width: Self.expandedWidth, height: Self.expandedHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            pillHovered = hovering
            refreshHelpState()
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isEngaged)
    }

    /// Drive `helpShown` from the four input signals (pillHovered,
    /// helpHovered, popoverHovered, helpPinned). Opens immediately when any
    /// "show" signal is true, closes after a short grace period when they all
    /// go false — so a quick cursor pass from `?` to the popover doesn't
    /// flicker the popover shut.
    private func refreshHelpState() {
        dismissTask?.cancel()
        let shouldShow = helpPinned || helpHovered || popoverHovered
        if shouldShow {
            helpShown = true
            return
        }
        // Nothing wants the popover open right now. If the pill is still
        // hovered, keep the popover state as-is (don't reopen it), but
        // schedule a debounced close so a cursor that briefly left the
        // ?-button can return without losing the popover.
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: Self.dismissDelay)
            guard !Task.isCancelled else { return }
            // Re-check on the trailing edge — state may have flipped during
            // the sleep (cursor re-entered, user clicked to pin, etc.).
            if !helpPinned, !helpHovered, !popoverHovered {
                helpShown = false
            }
        }
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
