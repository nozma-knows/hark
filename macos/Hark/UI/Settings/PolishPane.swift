import AppKit
import SwiftUI

/// Polish-profile configuration. The Default applies to every app
/// the user hasn't explicitly overridden; per-app overrides target
/// the bundle ID returned by `NSWorkspace.frontmostApplication` at
/// dictation time.
struct PolishPane: View {
    @Bindable var store: PolishProfileStore

    /// Picker state for adding a new per-app override.
    @State private var newBundleID: String = ""
    @State private var newProfile: PolishProfile = .standard

    var body: some View {
        Form {
            defaultSection
            overridesSection
            addSection
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Sections

    private var defaultSection: some View {
        Section {
            Picker("Default profile", selection: defaultBinding) {
                ForEach(PolishProfile.allCases) { profile in
                    profileLabel(profile).tag(profile)
                }
            }
            .pickerStyle(.menu)
            Text(store.defaultProfile.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Default polish")
        } footer: {
            Text("Applied to every app that doesn't have a specific override below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var overridesSection: some View {
        Section {
            if store.sortedOverrides.isEmpty {
                Text("No app-specific overrides yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.sortedOverrides, id: \.bundleID) { entry in
                    OverrideRow(
                        bundleID: entry.bundleID,
                        profile: entry.profile,
                        onChange: { store.setOverride($0, for: entry.bundleID) },
                        onDelete: { store.setOverride(nil, for: entry.bundleID) }
                    )
                }
            }
        } header: {
            Text("Per-app overrides")
        }
    }

    private var addSection: some View {
        Section {
            HStack {
                TextField("Bundle ID — e.g. com.apple.Notes", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Frontmost") {
                    if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        newBundleID = id
                    }
                }
                .buttonStyle(.bordered)
                .help("Fill with the current frontmost application's bundle ID")
            }

            Picker("Use profile", selection: $newProfile) {
                ForEach(PolishProfile.allCases) { profile in
                    profileLabel(profile).tag(profile)
                }
            }

            HStack {
                Spacer()
                Button("Add override") {
                    let trimmed = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.setOverride(newProfile, for: trimmed)
                    newBundleID = ""
                    newProfile = .standard
                }
                .buttonStyle(.borderedProminent)
                .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Add an app")
        } footer: {
            Text(
                """
                Bundle ID is the unique identifier macOS assigns each app \
                (com.apple.Notes, com.tinyspeck.slackmacgap, …). Click \
                "Frontmost" to copy it from the app currently in focus.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var defaultBinding: Binding<PolishProfile> {
        Binding(
            get: { store.defaultProfile },
            set: { store.setDefault($0) }
        )
    }

    private func profileLabel(_ profile: PolishProfile) -> some View {
        Text(profile.displayName)
    }
}

/// One row in the per-app overrides list.
private struct OverrideRow: View {
    let bundleID: String
    let profile: PolishProfile
    let onChange: (PolishProfile) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                Text(bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Picker(
                "",
                selection: Binding(
                    get: { profile },
                    set: { newValue in onChange(newValue) }
                )
            ) {
                ForEach(PolishProfile.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove override")
        }
        .padding(.vertical, 2)
    }

    /// Friendly display name for the bundle. Tries `NSWorkspace.url(forApplicationWithBundleIdentifier:)`
    /// + `Bundle.localizedInfoDictionary` lookup; falls back to the
    /// bundle ID itself when the app isn't installed (still useful
    /// for "I expect to install this app").
    private var displayName: String {
        if
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bundle = Bundle(url: url),
            let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
        {
            return name
        }
        return bundleID
    }
}
