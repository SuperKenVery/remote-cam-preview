# Remote Cam Preview TODO

本轮为了尽快完成 demo，只处理以下两个真机高风险项：

- Wi-Fi Aware NDP 同时汇合 `onCapabilitiesChanged` 与 `onLinkPropertiesChanged`，不再假定本地 IPv6 会先出现在 capabilities 回调中。
- Android 只协商相机输出与 HEVC 编码器共同支持的离散尺寸，并要求 CameraX 使用该尺寸；若厂商实现仍返回不同尺寸，立即结束媒体会话并报告明确错误，避免继续黑屏或错误解码。

## Demo 后优先处理

- [ ] Android `HevcDecoder` 改为阻塞等待输入，并在 codec 异常后完整释放、重建解码器、清空参数集并请求 IDR；当前异常路径可能留下黑屏状态。
- [ ] Android RTP depacketizer 为未收到 marker 的残帧增加超时淘汰；当前丢 marker 后可能等不到可交付/可丢弃边界。
- [ ] Android RTCP extended sequence number 正确处理 16-bit sequence wrap，补充跨回绕统计测试。
- [ ] Android 控制连接断开时关闭所有已 accept 的照片 HTTP socket；当前进行中的照片流可能继续到传输结束。
- [ ] Android 照片 GET 使用独立的有限 read/call timeout；旧照片协程必须绑定创建它的 session，禁止向后续新会话回报结果。
- [ ] 把设备旋转接入 `preview.reconfigure`、新 VPS/SPS/PPS 与 IDR 切换边界；完成四向动态旋转和安全区域验收。

## 跨平台与真机验收

- [ ] 解决 Android Aware Pairing 缓存的 NPK/NIK 无法通过公开 API 导出为 `WifiAwareNetworkSpecifier` PMK 的跨平台安全 NDP 凭据交换；在此之前不能为了 demo 静默退化为开放 NDP。
- [ ] 在至少一台支持 Wi-Fi Aware 的 iPhone/iPad 与 Android 真机上双向验证：发现/配对/NDP、HEVC 30 fps/约 10 Mbps、协商尺寸、照片 SHA-256、断线回收和玻璃到玻璃延迟。
- [ ] 修复本机 Xcode/CoreSimulator runtime 版本不匹配后实际执行 iOS XCTest；目前仅完成 `build-for-testing` 编译。

详细真机步骤见 [`docs/device-test-plan.md`](docs/device-test-plan.md)，当前自动化证据见 [`docs/verification.md`](docs/verification.md)。
