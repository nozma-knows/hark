import SwiftUI

struct PermissionCard: View {
    enum Status {
        case pending
        case granted
        case denied
    }

    let systemImage: String
    let title: String
    let description: String
    let status: Status
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    statusBadge
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(status == .granted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    private var statusBadge: some View {
        Group {
            switch status {
            case .pending:
                Label("Required", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Denied", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .labelStyle(.iconOnly)
        .font(.callout)
    }
}

#Preview {
    VStack(spacing: 12) {
        PermissionCard(
            systemImage: "mic.fill",
            title: "Microphone",
            description: "Capture your voice locally.",
            status: .pending,
            actionLabel: "Grant",
            action: {}
        )
        PermissionCard(
            systemImage: "keyboard",
            title: "Accessibility",
            description: "Watch for the global hotkey.",
            status: .granted,
            actionLabel: "Granted",
            action: {}
        )
        PermissionCard(
            systemImage: "mic.fill",
            title: "Microphone",
            description: "Capture your voice locally.",
            status: .denied,
            actionLabel: "Open Settings",
            action: {}
        )
    }
    .padding()
    .frame(width: 460)
}
