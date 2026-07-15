import DeviceDiscoveryUI
import Network
import SwiftUI
import WiFiAware

struct WiFiAwarePairingControls: View {
    let role: DeviceRole
    let pairedDevices: [WAPairedDevice]
    let onPairingPresented: () -> Void
    let onPairingDismissed: () -> Void
    let onStartPublishing: (WAPairedDevice) -> Void
    let onEndpointSelected: (WAEndpoint) -> Void

    var body: some View {
        if let publishService, let subscribeService {
            VStack(spacing: 10) {
                if role == .camera {
                    DevicePairingView(
                        .wifiAware(
                            .connecting(
                                to: publishService,
                                from: .userSpecifiedDevices,
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

                    if pairedDevices.isEmpty {
                        Text("请先通过系统界面与监看端配对。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pairedDevices) { peer in
                            Button {
                                onStartPublishing(peer)
                            } label: {
                                Label(
                                    "启动控制服务，等待 \(peer.name ?? "已配对设备")",
                                    systemImage: "antenna.radiowaves.left.and.right"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Text("系统配对完成后，还必须点击上方“启动控制服务”；仅完成配对不会开始监听。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DevicePicker(
                        .wifiAware(
                            .connecting(to: .userSpecifiedDevices, from: subscribeService)
                        ),
                        access: .permanent,
                        onSelect: { endpoint in
                            onPairingDismissed()
                            onEndpointSelected(endpoint)
                        },
                        label: {
                            Label("查找并连接", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        },
                        fallback: {
                            Label("系统查找不可用", systemImage: "exclamationmark.triangle")
                        },
                        parameters: {
                            NWParameters.tcp
                                .wifiAware { $0.performanceMode = .realtime }
                        }
                    )
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
