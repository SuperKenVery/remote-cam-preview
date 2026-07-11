import SwiftUI

struct SessionView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var presentedError: SessionErrorReport?
    let session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            if session.role == .camera {
                CameraScreen(session: session, camera: dependencies.camera)
            } else {
                MonitorScreen(session: session, mediaPipeline: dependencies.mediaPipeline)
            }

            Divider()
            ConnectionPanel(
                session: session,
                onShowError: { presentedError = $0 }
            )
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
        .onChange(of: session.lastError) { _, report in
            if let report { presentedError = report }
        }
        .sheet(item: $presentedError) { report in
            SessionErrorDetailView(report: report)
                .presentationDetents([.medium, .large])
        }
    }
}

private struct ConnectionPanel: View {
    @Environment(AppDependencies.self) private var dependencies
    let session: AppSession
    let onShowError: (SessionErrorReport) -> Void

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
                    pairedDevices: dependencies.wifiAware.pairedDevices,
                    onPairingPresented: { session.pairerPresented() },
                    onPairingDismissed: { session.pairingDismissed() },
                    onStartPublishing: { session.startPublishing(to: $0) },
                    onEndpointSelected: { session.connect(to: $0) }
                )
            }

            if let photoTransferStatus = session.photoTransferStatus {
                Label(photoTransferStatus, systemImage: "photo.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let report = session.lastError {
                Button {
                    onShowError(report)
                } label: {
                    Label("查看错误详情", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.bordered)
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

private struct SessionErrorDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let report: SessionErrorReport

    var body: some View {
        NavigationStack {
            Form {
                Section("发生阶段") {
                    Text(report.stage)
                }

                Section("错误信息") {
                    Text(report.message)
                    LabeledContent("错误域", value: report.domain)
                    LabeledContent("错误代码", value: String(report.code))
                }

                if let underlyingDomain = report.underlyingDomain,
                   let underlyingCode = report.underlyingCode {
                    Section("底层错误") {
                        if let underlyingMessage = report.underlyingMessage {
                            Text(underlyingMessage)
                        }
                        LabeledContent("错误域", value: underlyingDomain)
                        LabeledContent("错误代码", value: String(underlyingCode))
                    }
                }

                Section("建议") {
                    Text(report.suggestion)
                }

                Section {
                    ShareLink(item: diagnosticText) {
                        Label("分享诊断信息", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("诊断信息不包含会话令牌或照片内容。")
                }
            }
            .navigationTitle(report.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var diagnosticText: String {
        var lines = [
            "Remote Cam Preview",
            "标题：\(report.title)",
            "阶段：\(report.stage)",
            "错误：\(report.message)",
            "域/代码：\(report.domain) / \(report.code)"
        ]
        if let domain = report.underlyingDomain,
           let code = report.underlyingCode {
            lines.append("底层域/代码：\(domain) / \(code)")
        }
        if let message = report.underlyingMessage {
            lines.append("底层错误：\(message)")
        }
        lines.append("建议：\(report.suggestion)")
        return lines.joined(separator: "\n")
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
