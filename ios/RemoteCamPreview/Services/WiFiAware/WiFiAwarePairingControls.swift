import DeviceDiscoveryUI
import SwiftUI
import WiFiAware

struct WiFiAwarePairingControls: View {
    let role: DeviceRole
    let onPairingPresented: () -> Void
    let onPairingDismissed: () -> Void
    let onStartPublishing: () -> Void
    let onEndpointSelected: (WAEndpoint) -> Void

    var body: some View {
        if let publishService, let subscribeService {
            VStack(spacing: 10) {
                if role == .camera {
                    DevicePairingView(
                        .wifiAware(
                            .connecting(
                                to: publishService,
                                from: .selected([]),
                                datapath: .realtime
                            )
                        ),
                        access: .permanent
                    ) {
                        Label("使本机可被配对", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    } fallback: {
                        Label("系统配对不可用", systemImage: "exclamationmark.triangle")
                    }
                    .simultaneousGesture(TapGesture().onEnded(onPairingPresented))
                    .buttonStyle(.bordered)

                    Button(action: onStartPublishing) {
                        Label("等待监看端连接", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("拍摄端提供本次会话的控制、预览和成片服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DevicePicker(
                        .wifiAware(
                            .connecting(to: .selected([]), from: subscribeService)
                        ),
                        access: .permanent,
                        onSelect: { endpoint in
                            onPairingDismissed()
                            onEndpointSelected(endpoint)
                        }
                    ) {
                        Label("查找并连接", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    } fallback: {
                        Label("系统查找不可用", systemImage: "exclamationmark.triangle")
                    }
                    .simultaneousGesture(TapGesture().onEnded(onPairingPresented))
                    .buttonStyle(.borderedProminent)

                    Text("监看端选择拍摄端后主动建立控制连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Wi-Fi Aware 服务声明缺失", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var publishService: WAPublishableService? {
        WAPublishableService.allServices[WiFiAwareController.serviceName]
    }

    private var subscribeService: WASubscribableService? {
        WASubscribableService.allServices[WiFiAwareController.serviceName]
    }
}
