import SwiftUI

struct SessionView: View {
    @Environment(AppDependencies.self) private var dependencies
    let session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            if session.role == .camera {
                CameraScreen(session: session, camera: dependencies.camera)
            } else {
                MonitorScreen(session: session, mediaPipeline: dependencies.mediaPipeline)
            }

            Divider()
            ConnectionPanel(session: session)
                .padding()
                .background(.regularMaterial)
        }
        .navigationTitle(session.role?.title ?? "会话")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("结束") { session.endSession() }
            }
        }
        .task { await session.startCameraIfNeeded() }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好") { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "未知错误")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )
    }
}

private struct ConnectionPanel: View {
    let session: AppSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConnectionStatusView(phase: session.phase, detail: session.statusDetail)

            switch session.phase {
            case .connected:
                if session.role == .monitor {
                    Toggle("接收最终成片", isOn: receivePhotosBinding)
                        .accessibilityIdentifier("receivePhotos.toggle")
                }
            case .unavailable(let availability):
                Text(availability.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if availability.isRetryable {
                    retryButton
                }
            case .interrupted:
                retryButton
            default:
                WiFiAwarePairingControls(
                    role: session.role ?? .monitor,
                    onPairingPresented: { session.pairerPresented() },
                    onPairingDismissed: { session.pairingDismissed() },
                    onStartPublishing: { session.startPublishing() },
                    onEndpointSelected: { session.connect(to: $0) }
                )
            }

            if let photoTransferStatus = session.photoTransferStatus {
                Label(photoTransferStatus, systemImage: "photo.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var receivePhotosBinding: Binding<Bool> {
        Binding(
            get: { session.receivePhotos },
            set: { enabled in
                Task { await session.updateReceivePhotos(enabled) }
            }
        )
    }

    private var retryButton: some View {
        Button("重试") { Task { await session.retry() } }
            .buttonStyle(.borderedProminent)
    }
}

private struct ConnectionStatusView: View {
    let phase: SessionPhase
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        switch phase {
        case .checkingCapability: "正在检查能力"
        case .unavailable(let availability): availability.title
        case .roleSelection: "请选择角色"
        case .unpaired: "尚未连接"
        case .searching: "正在等待对方"
        case .pairing: "正在使用系统界面配对"
        case .connecting: "正在建立数据路径"
        case .connected(let peerName): peerName.map { "已连接：\($0)" } ?? "已连接"
        case .interrupted(let reason): "连接中断：\(reason)"
        }
    }

    private var icon: String {
        switch phase {
        case .connected: "wifi.circle.fill"
        case .unavailable, .interrupted: "wifi.exclamationmark"
        case .searching, .pairing, .connecting: "wifi.circle"
        default: "wifi.slash"
        }
    }

    private var color: Color {
        switch phase {
        case .connected: .green
        case .unavailable, .interrupted: .orange
        default: .secondary
        }
    }
}
