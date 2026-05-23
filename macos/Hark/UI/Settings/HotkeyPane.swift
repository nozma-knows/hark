import SwiftUI

/// Global hotkey configuration — surfaces the active key combo and lets
/// the user pick between hold-to-talk and toggle behavior. The hotkey
/// itself is hardcoded to Fn (🌐) because rebinding it requires
/// matching CGEvent tap surgery; only the mode is user-tunable today.
struct HotkeyPane: View {
    @Bindable var hotkey: HotkeyManager

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Global hotkey")
                    Spacer()
                    Text(hotkey.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(.tint.opacity(0.15))
                        )
                        .foregroundStyle(.tint)
                }
            } footer: {
                Text("Uses the Fn (🌐) key. If Fn opens emoji or dictation, set Keyboard → 🌐 to \"Do Nothing\".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mode", selection: $hotkey.mode) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(hotkey.mode.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
