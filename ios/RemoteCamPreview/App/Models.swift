import CoreGraphics
import Foundation

enum DeviceRole: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case camera
    case monitor

    var id: Self { self }

    var title: String {
        switch self {
        case .camera: "拍摄端"
        case .monitor: "监看端"
        }
    }

    var subtitle: String {
        switch self {
        case .camera: "本机取景、拍照并发送低延迟预览"
        case .monitor: "查看远端取景，可选择接收最终成片"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera.fill"
        case .monitor: "rectangle.inset.filled.and.person.filled"
        }
    }
}

enum AppRoute: Hashable {
    case session
}

enum SessionPhase: Equatable, Sendable {
    case checkingCapability
    case unavailable(WiFiAwareAvailability)
    case roleSelection
    case unpaired
    case searching
    case pairing
    case connecting
    case connected(peerName: String?)
    case interrupted(reason: String)

    var isRecoverable: Bool {
        switch self {
        case .unavailable(let availability): availability.isRetryable
        case .interrupted: true
        default: false
        }
    }
}

enum WiFiAwareAvailability: Equatable, Sendable {
    case available
    case unsupported
    case serviceDeclarationMissing
    case entitlementMissing
    case noRadioResources
    case unavailable(reason: String, retryable: Bool)

    var isRetryable: Bool {
        switch self {
        case .noRadioResources: true
        case .unavailable(_, let retryable): retryable
        default: false
        }
    }

    var title: String {
        switch self {
        case .available: "Wi-Fi Aware 可用"
        case .unsupported: "设备不支持 Wi-Fi Aware"
        case .serviceDeclarationMissing: "应用配置不完整"
        case .entitlementMissing: "缺少 Wi-Fi Aware 权限"
        case .noRadioResources: "无线资源暂时不可用"
        case .unavailable: "Wi-Fi Aware 当前不可用"
        }
    }

    var guidance: String {
        switch self {
        case .available:
            "可通过系统界面配对附近设备。"
        case .unsupported:
            "本应用没有热点或互联网降级方案。请换用支持 Wi-Fi Aware 的 iOS 26 设备。"
        case .serviceDeclarationMissing:
            "请确认 Info.plist 已声明 _remote-cam._tcp 服务后重新安装。"
        case .entitlementMissing:
            "当前签名或描述文件没有 Wi-Fi Aware entitlement。请联系开发者。"
        case .noRadioResources:
            "结束其他点对点连接，确认 Wi-Fi 已开启，然后重试。"
        case .unavailable(let reason, _):
            reason
        }
    }
}

enum PreviewOrientation: String, Codable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}

struct PixelDimensions: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    var area: Int { width * height }
    var aspectRatio: Double { height == 0 ? 0 : Double(width) / Double(height) }
}

struct HEVCDecodeCapabilities: Codable, Equatable, Sendable {
    var supported: Bool
    var maximumDimensions: PixelDimensions
    var maximumFramesPerSecond: Int
    var profiles: [String]
}

struct MonitorDisplayCapabilities: Codable, Equatable, Sendable {
    var nativePixels: PixelDimensions
    var viewportPixels: PixelDimensions
    var orientation: PreviewOrientation
    var hevc: HEVCDecodeCapabilities
}

struct PreviewConfiguration: Codable, Equatable, Sendable {
    var dimensions: PixelDimensions
    var framesPerSecond: Int
    var bitrate: Int
    var profile: String
    var level: String
}

struct CaptureFormatCandidate: Equatable, Sendable {
    var dimensions: PixelDimensions
    var maximumFramesPerSecond: Int
}

