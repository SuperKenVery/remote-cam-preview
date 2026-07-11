import SwiftUI

struct RoleSelectionView: View {
    let session: AppSession

    var body: some View {
        Group {
            switch session.phase {
            case .checkingCapability:
                ContentUnavailableView {
                    Label("正在检查设备", systemImage: "wifi.circle")
                } description: {
                    Text("正在确认 Wi-Fi Aware 服务、硬件和签名能力。")
                }

            case .unavailable(let availability):
                AvailabilityFailureView(availability: availability) {
                    Task { await session.prepare() }
                }

            default:
                roleChooser
            }
        }
        .navigationTitle("Remote Cam")
    }

    private var roleChooser: some View {
        List {
            Section {
                ForEach(DeviceRole.allCases) { role in
                    Button {
                        session.choose(role)
                    } label: {
                        RoleRow(role: role)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("role.\(role.rawValue)")
                }
            } header: {
                Text("选择本次会话角色")
            } footer: {
                Text("角色在会话中固定。Wi-Fi Aware 的发布/订阅方向会在下一步单独选择。")
            }

            Section("隐私") {
                Label("纯点对点，不使用互联网或云端", systemImage: "lock.shield")
                Label("没有账号，不上传照片或设备信息", systemImage: "person.crop.circle.badge.xmark")
            }
        }
    }
}

private struct RoleRow: View {
    let role: DeviceRole

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: role.systemImage)
                .font(.title2)
                .frame(width: 36, height: 36)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(role.title).font(.headline)
                Text(role.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.vertical, 8)
    }
}

private struct AvailabilityFailureView: View {
    let availability: WiFiAwareAvailability
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(availability.title, systemImage: "wifi.exclamationmark")
        } description: {
            Text(availability.guidance)
        } actions: {
            if availability.isRetryable {
                Button("重新检查", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

