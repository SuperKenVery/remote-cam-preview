# Remote Cam Preview

Remote Cam Preview 是一套原生 iOS 26 与 Android 双端应用工程。两台支持 Wi‑Fi Aware 的设备可在没有互联网、路由器、热点或账号的情况下建立经过系统配对的点对点数据路径：拍摄端在应用内拍照并发送低延迟 HEVC 预览，监看端显示预览并可选择是否接收最终成片。

> 当前仓库提供可构建的协议与双端实现，但不把尚未执行的真机互操作测试标记为通过。尤其是 Android 公开 API 的 [`AwarePairingConfig`](https://developer.android.com/reference/android/net/wifi/aware/AwarePairingConfig) 能让系统缓存 NPK/NIK，却没有导出接口供旧式 [`WifiAwareNetworkSpecifier`](https://developer.android.com/reference/android/net/wifi/aware/WifiAwareNetworkSpecifier.Builder) 配置安全 NDP；后者仍要求应用提供 PSK 或 PMK。代码会在缺少经过认证的临时 NDP 凭据时明确停止，而不会退回开放链路或固定口令。该接口边界必须用目标 Android 厂商栈与 iOS 真机验证，并在可获得的跨端凭据引导机制确定后补齐。
>
> 另一个明确边界是 iOS 26.0–26.3：这些版本没有 26.4 的 additional-connections API，Swift 实现会为 RTP、RTCP 与照片使用额外 Aware service；当前 Android 实现尚未建立这些附加 service/NDP。因此现有跨平台候选路径要求 iOS 26.4+，并不宣称已满足任务对整个 iOS 26.x 的最低版本验收。

仓库从同一份版本化协议定义生成行为约束，而不是让 Swift 与 Kotlin 各自决定线格式：

- `protocol/`：JSON Schema、跨平台测试向量、RFC 7798 HEVC/RTP、RTCP RR/PLI、会话状态机及流式照片校验参考实现。
- `ios/`：SwiftUI、WiFiAware/DeviceDiscoveryUI、AVFoundation、VideoToolbox、Network.framework 与 Photos 实现；最低 iOS 26。
- `android/`：Jetpack Compose、WifiAwareManager、CameraX、MediaCodec、OkHttp/UDP 与 MediaStore 实现；最低 API 31，API 34+ 使用系统 Aware Pairing 能力。
- `docs/`：架构、隐私边界和可重复真机验收步骤。

## 开发环境

在仓库根目录进入固定工具环境：

```sh
nix develop
```

flake 固定 Android platform/build-tools 36、JDK 21、Gradle、Kotlin CLI、ktlint、detekt、Python 与格式化工具。Xcode 26+、iOS SDK、Apple Developer 签名、Wi‑Fi Aware entitlement、Provisioning Profile 和真机由 macOS/Xcode 提供，不封装进 Nix。

常用检查：

```sh
make protocol-test
make ios-build
make android-test
nix flake check
```

协议测试不依赖第三方 Python 包，也可直接运行：

```sh
python3 protocol/run_reference_tests.py
```

## iOS

先生成 Xcode 工程，再打开或命令行构建：

```sh
make ios-project
open ios/RemoteCamPreview.xcodeproj
```

真机前必须把 `com.example.RemoteCamPreview` 换成团队拥有的 bundle identifier，并在 Apple Developer/Xcode 中启用 Wi‑Fi Aware 的 Publish 与 Subscribe 能力。配置详情见 `ios/README.md`。

## Android

在 `nix develop` 中运行：

```sh
cd android
./gradlew test
./gradlew assembleDebug
```

Android 13+ 会按需请求 Nearby Wi‑Fi Devices；API 31–32 使用受版本限制的定位权限声明。应用启动后仍会检查硬件特性、当前 Aware 可用性、无线权限、会话资源、相机和 HEVC 编解码能力，不支持或当前不可用时不会进入配对流程。

## 必须在真机完成的验收

模拟器可以验证 UI、协议、状态机和完整性逻辑，但不能证明 Wi‑Fi Aware、硬件 HEVC、相机处理或照片库链路。交付前必须用至少一台受支持 iPhone/iPad 与一台受支持 Android 设备完成 iOS→Android 和 Android→iOS 两个方向，记录 30 fps / 约 10 Mbps、协商分辨率、方向切换、照片 SHA‑256 以及玻璃到玻璃延迟。完整步骤见 `docs/device-test-plan.md`。

仓库不会把尚未执行的真机互操作测试标记为通过；代码层测试通过与硬件验收是两个独立门槛。
本次实际执行的自动化结果与仍未通过的项目记录在 [`docs/verification.md`](docs/verification.md)。
