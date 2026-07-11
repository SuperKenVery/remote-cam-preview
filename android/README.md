# Remote Cam Preview — Android

原生 Kotlin / Jetpack Compose 客户端，`compileSdk` / `targetSdk` 36，`minSdk` 31。应用可安装在不支持 Wi‑Fi Aware 的设备上，并在启动页解释不可用原因；不会尝试热点、普通局域网、Wi‑Fi Direct、蓝牙或互联网降级。

## 构建与测试

在仓库根目录进入固定的 Nix 环境：

```sh
nix develop
cd android
./gradlew testDebugUnitTest
./gradlew assembleDebug
```

JVM 测试直接读取 `../protocol/vectors/v1` 的同一份控制消息、HEVC/RTP、照片完整性和状态机向量，不维护 Android 私有副本。

## 实现边界

- 能力与权限：运行时检测 `FEATURE_WIFI_AWARE`、`WifiAwareManager.isAvailable`、Aware 资源、Camera 和 HEVC 编解码器。Android 13+ 请求 `NEARBY_WIFI_DEVICES`（`neverForLocation`），Android 12/12L 请求定位；只有拍摄角色请求 Camera。
- 发现与配对：on-air service name 固定为 `_remote-cam._tcp`。两种应用角色均同时 publish 和 subscribe，角色作为 service-specific info 传输。建立本次 NDP 时选用拍摄端已存在的 publish candidate 与监看端已存在的 subscribe candidate，这是因为 Android 公共 API 只允许 publisher server 在 secure NDP 上写入 TCP port/transport metadata；并没有省略任一角色的双向发现能力。API 34+ 宣告 NAN Pairing setup / verification / cache，收到请求后仍需用户明确选择。
- 安全数据路径：`WifiAwareController.requestSecureDataPath` 强制接收 `SecureDataPathCredential`，永不创建 open NDP。只有 publisher 同时作为 TCP server 时才写 port / transport protocol 元数据。
- 相机：本地 `PreviewView` 与独立 `ImageCapture`。照片由静态 CameraX 管线直接写入 MediaStore，不从视频流截帧；Android 10+ 写入应用新建的 MediaStore 项目不需要旧式存储写权限。
- 预览：CameraX `VideoOutput` 将相机 surface 交给 HEVC `MediaCodec`；30 fps、10 Mbps、CBR、无 B 帧、一秒 GOP、参数集随 IDR。解码器启用低延迟模式并把输入队列限制为三帧。
- 方向：初始协商会携带视口方向，CameraX 在本机旋转后重新绑定 target rotation，监看 TextureView 使用等比居中裁切。会话中的 `preview.reconfigure` + 新参数集/IDR 切换尚未接入生产状态机，四向动态旋转仍是明确的真机验收缺口。
- RTP/RTCP：RFC 7798 单 NAL、AP 和 FU，90 kHz 时钟，完整 RTP 包默认 1200 字节，随机非零 SSRC；包数、NAL 数、NAL 大小和 access unit 大小都有硬上限。A 在 accepted 所列 RTP/RTCP 端口监听，B 从最终接收 RTP 的同一 UDP socket 先发 ASCII `RCP1` probe，A 再向该 5-tuple 发流。B 立即并周期发送 RTCP RR，坏帧同时经 RTCP PLI / WebSocket 请求 IDR。接收端只保留四帧、20 ms 重排窗口，坏帧直接丢弃。
- 控制与成片：拍摄端在 Aware IPv6 地址上提供真正的 HTTP/1.1 + RFC 6455 `/v1/events` WebSocket，并提供 `GET /v1/photos/{photoId}`。监看端 OkHttp 的 socket factory 和 DNS 映射固定到本次 Aware `Network`。照片流先写私有临时文件，长度和 SHA‑256 均一致后才写入 MediaStore。
- 会话资源：每次会话使用随机 session ID、Bearer token 与 PSK 容器。`/v1/events` 初次升级不可能携带尚未下发的 token；它只接受 Aware-bound peer，并要求 5 秒内由 B 首发带新 session ID 的 `session.hello`，A 将连接绑定到该 ID，并在 `session.accepted` 回显、下发 token。Bearer 只用于后续照片 GET / health。WebSocket 断开由上层立即停止预览和照片资源，照片下载使用独立 TCP 连接，RTP 使用独立 UDP socket。

## Wi‑Fi Aware Pairing 的平台限制

Android API 34 的公开接口可以配置 pairing setup / verification、得到 paired alias，但不能把系统缓存的 NPK/NIK 导出为 `WifiAwareNetworkSpecifier` 所需的 PMK。工程因此刻意把“系统配对已验证”和“安全 NDP 凭据已协商”建模为两个阶段：没有跨端协商出的临时凭据就报错，不会偷偷建立开放链路。

这意味着 Android ↔ iOS 的 pairing/NDP 互操作必须在 API 34+ 且厂商声明 Aware Pairing 的真机上验证；当前公共 Android API 是否由厂商栈自动复用配对密钥不能从模拟器或 JVM 测试证明。跨端凭据引导层在协议确定前以明确接口保留，未声称已由固定 PSK 代替系统配对。

跨平台实现当前要求 iOS 26.4+ 的 numeric port endpoint；iOS 26.0–26.3 使用 `_remote-photo._tcp` / `_remote-preview._udp` / `_remote-feedback._udp` service-name fallback，而 Android 本轮没有可靠实现这三组额外发现与 NDP 映射。26.0–26.3 因而不满足 Android ↔ iOS 验收，只能作为 iOS ↔ iOS 候选且仍需真机验证。

## 真机验收清单

每组设备至少记录型号、系统版本、`isAwarePairingSupported`、可用 publish/subscribe/NDP 数、HEVC 编解码上限和 CameraX 实际输出尺寸。

1. 关闭路由器连接与蜂窝数据，只保留 Wi‑Fi 无线功能；确认两端发现 `_remote-cam._tcp`。
2. 分别验证 Android 担任拍摄端和监看端；确认两端同角色时不会连接，且 publish/subscribe 与应用角色无硬编码关系。
3. 首次配对必须显示候选并手动确认；结束再连接时记录 cached alias verification 是否成功。
4. 用 `ConnectivityManager` / socket 日志确认 TCP、HTTP、WebSocket 和 UDP socket 都在 Aware `Network` / link-local IPv6 地址上，无普通 Wi‑Fi 或蜂窝流量。
5. 用快速运动和两端同拍计时器测量玻璃到玻璃延迟，记录 30 fps / 10 Mbps 下 P50、P95；目标 P95 < 200 ms。
6. 四个方向旋转设备，确认控制通道先发 reconfigure，随后参数集 + IDR，画面使用 `FILL_CENTER` 且不拉伸。
7. 拍照后确认 A 的 MediaStore 文件来自 `ImageCapture`。B 开启时检查下载长度/SHA‑256、再保存；关闭时确认 A 仍保存、B 不发 GET 且不创建媒体项。
8. 成片下载同时持续记录 RTP 序号、丢包、抖动和预览帧间隔，确认 TCP 下载不会造成长时间冻结。
9. 逐项测试附近设备权限拒绝、Camera 权限拒绝、Wi‑Fi 关闭、Aware 资源耗尽、配对失败、WebSocket 断开、UDP 丢包、照片被截断、SHA‑256 错误和 MediaStore 写入失败。
