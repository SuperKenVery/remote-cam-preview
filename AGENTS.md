# Remote Cam Preview 开发指南

## 项目目标

本仓库实现原生 iOS 与 Android 双端远程相机预览。两台支持 Wi‑Fi Aware 的设备在没有互联网、路由器、热点或账号的情况下建立点对点会话：

- **A / Capture（拍摄端）**：本地显示相机、拍摄并保存成片，同时编码低延迟 HEVC 预览。
- **B / Monitor（监看端）**：显示远端预览，并按用户开关决定是否拉取最终成片。

两个 App 都能选择任一应用角色。Wi‑Fi Aware 的 publish/subscribe 角色只服务于发现和数据路径建立，不能据此推断 Capture/Monitor 角色。

## 总体架构

一次会话包含三条相互独立的逻辑通道，全部必须绑定到本次 Wi‑Fi Aware 数据路径：

| 通道 | 传输 | 方向 | 用途 |
| --- | --- | --- | --- |
| Control | HTTP/1.1 Upgrade + WebSocket/TCP | B 连接 A | 能力协商、预览命令、心跳、照片事件 |
| Preview | HEVC/RTP + RTCP/UDP | A 发 RTP，B 发 RR/PLI | 低延迟预览、丢包统计与 IDR 请求 |
| Photo | HTTP GET/TCP | B 从 A 拉取 | 传输相机静态管线产生的最终成片 |

核心会话流程：

1. 用户选择角色，应用检查 Wi‑Fi Aware、权限、相机和 HEVC 能力。
2. 两端发现并明确选择对端，完成系统配对和安全 NDP。
3. B 建立 WebSocket，首条消息发送 `session.hello`，包括随机 session ID、视口和解码能力。
4. A 选择双方共同支持的离散编码尺寸，返回 `session.accepted`、随机 access token、RTP/RTCP 和照片端点。
5. B 发送 `preview.start`，A 通过硬件 HEVC 编码器和 RFC 7798 RTP 发流；B 解码并 aspect-fill 显示。
6. A 拍照时使用独立静态相机管线先保存本地文件；B 开启接收后再通过 HTTP 拉取，校验长度和 SHA-256 后写入系统相册。
7. 控制断开、能力丢失或主动结束时，媒体、令牌、临时照片和网络资源应立即失效。

共享状态大致为：

```text
unpaired -> discovering -> pairing -> connecting -> connected
                                \-> interrupted -> retry -> discovering
active state -> unavailable
active state -> ended
```

## 目录职责

### `protocol/`

跨平台线协议的唯一真源，包含：

- `schemas/v1/`：控制消息与照片元数据 JSON Schema。
- `vectors/v1/`：Swift、Kotlin、Python 共用的控制、状态机、RTP、RTCP 和照片测试向量。
- `reference/`：仅依赖 Python 标准库的防御性参考实现。
- `tests/`：协议资源上限、严格解析、幂等、包化和完整性测试。

改变线格式或字段语义时，先改协议定义、参考实现和共享向量，再同步两端；不要让 Swift/Kotlin 各自形成私有协议。破坏兼容性的修改必须新建主版本目录，不能直接重写 v1 语义。

### `ios/`

SwiftUI + iOS 26 原生实现：

- `App/AppSession.swift`：会话编排和主要状态所有者。
- `Services/WiFiAware/`：发现、配对、`WAEndpoint` 与额外连接。
- `Services/Network/`：控制 WebSocket、会话状态机、UDP 预览传输和照片 HTTP。
- `Services/Media/`：VideoToolbox HEVC、RFC 7798、RTCP 与远端画面渲染。
- `Services/Camera/`、`Services/Photos/`：AVFoundation 静态拍照与 Photos 写入。
- `Features/`：角色选择、会话、拍摄端和监看端 SwiftUI 页面。
- `RemoteCamPreviewTests/`：协议与纯逻辑 XCTest。

`ios/project.yml` 是 Xcode 工程配置真源。`ios/RemoteCamPreview.xcodeproj` 由 XcodeGen 生成并被忽略，不要手工维护其中的 `project.pbxproj`。

### `android/`

Kotlin + Jetpack Compose 原生实现：

- `RemoteCamViewModel.kt`：应用会话编排、角色状态与各服务生命周期。
- `aware/WifiAwareController.kt`：发现、配对、安全 NDP 与 scoped `Network`。
- `capability/DeviceCapabilityChecker.kt`：运行时能力以及相机/HEVC 离散尺寸交集。
- `camera/CameraController.kt`：CameraX Preview、ImageCapture 与 VideoOutput 绑定。
- `media/HevcCodec.kt`：MediaCodec surface 输入编码和低延迟解码。
- `network/`：WebSocket/HTTP、RTP/RTCP UDP 与 Aware Network 绑定。
- `protocol/`、`session/`：严格控制消息、RFC 7798 与状态/分辨率协商。
- `photo/`：静态成片暂存、SHA-256 校验和 MediaStore 写入。
- `MainActivity.kt`：Compose UI、权限入口与视频 Surface。

Android JVM 测试直接读取仓库根目录的 `protocol/vectors/v1`，不要复制一份 Android 专用向量。

### `docs/` 与 `TODO.md`

- `docs/architecture.md`：更完整的信任边界和数据流。
- `docs/privacy.md`：隐私与网络绑定要求。
- `docs/device-test-plan.md`：真机双向验收步骤。
- `docs/verification.md`：实际执行过的自动化证据与未验证项。
- `TODO.md`：为快速 demo 暂缓的已知问题和平台阻断项。

## 必须保持的设计不变量

- 不得回退到普通 Wi‑Fi、热点、Wi‑Fi Direct、蓝牙、蜂窝或互联网。
- socket 必须绑定当前 `WAEndpoint` 或 Android Aware `Network`；不得监听 wildcard/普通接口。
- 不得用开放 NDP、固定 PSK 或从公开发现元数据派生口令来掩盖安全凭据缺失。
- 每次会话使用新的随机 session ID 和 access token；控制断开后不得复用。
- 初始 WebSocket 在 token 下发前依靠 Aware 对端绑定，并要求 5 秒内首发 `session.hello`。
- 预览必须是 HEVC；RTP 遵循仓库定义的 RFC 7798 子集、90 kHz 时钟和资源上限。
- 协商尺寸必须是相机、编码器和解码器真正共同支持的离散尺寸。CameraX/AVFoundation 实际输出不一致时应显式失败或先重配置，不能静默继续。
- 最终成片必须来自 AVFoundation/CameraX 静态照片管线，不能从预览帧截图代替。
- 照片只有在长度与 SHA-256 校验成功后才能写入监看端相册。
- 不要把模拟器、JVM 或协议测试通过描述为 Wi‑Fi Aware/硬件 HEVC 真机验收通过。

## 开发与验证

优先在仓库根目录使用固定环境：

```sh
nix develop
```

常用命令：

```sh
# 共享协议
make protocol-test

# iOS：先由 project.yml 生成工程
make ios-project
make ios-build

# Android
make android-test
cd android && ./gradlew assembleDebug

# Nix 配置和协议检查
nix flake check
```

改动协议、状态机、RTP/RTCP、照片完整性或协商逻辑时，必须补共享向量或平台单测。改动 Wi‑Fi Aware、相机、硬件 codec、方向或照片库行为时，除自动化外还要按 `docs/device-test-plan.md` 记录真机结果。

## 当前平台边界

- Android 公开 Aware Pairing API 无法直接导出缓存 NPK/NIK 给 `WifiAwareNetworkSpecifier` 使用，跨平台安全 NDP 仍需目标设备验证与凭据引导方案。
- 现有 Android ↔ iOS 候选路径要求 iOS 26.4+；iOS 26.0–26.3 的额外 service 路径尚未在 Android 接通。
- 动态四向旋转、解码器异常恢复、部分 RTP/RTCP 边界和照片断线回收仍在 `TODO.md`。

开发时应保留这些显式失败和文档边界，不要为了让 demo 看似可用而加入不安全降级或宣称未执行的真机验收。
