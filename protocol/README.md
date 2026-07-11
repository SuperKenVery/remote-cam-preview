# Remote Cam Preview 共享协议 v1

本目录是 iOS 与 Android 实现共同遵循的协议源。`schemas/v1/` 是 JSON
消息的机器可读定义，`vectors/v1/` 是两端必须逐字节通过的共享向量，
`reference/` 是只使用 Python 标准库的防御性参考实现。

当前线协议版本是 `1.0`。`v1` 目录一经发布只允许向后兼容地增加可选字段；
改变必需字段、字段语义、二进制封装或资源上限时必须建立新的主版本目录。

## 传输与端点

拍摄端 A 只在本次 Wi-Fi Aware 数据路径对应的接口和已配对对端上提供：

| 通道 | 端点/传输 | 发起方 | 用途 |
| --- | --- | --- | --- |
| 控制 | WebSocket `GET /v1/events`（TCP） | B | 协商、命令、事件、心跳 |
| 预览 | RTP/RTCP over UDP | B 连接 A 的端口；A 发 RTP，B 发 RTCP | HEVC 预览与反馈 |
| 成片 | HTTP `GET /v1/photos/{photoId}`（TCP） | B | 流式拉取最终成片 |

A 不得在普通 Wi-Fi、蜂窝或通配地址上监听这些服务。底层 Aware 的
publish/subscribe 角色不等同于应用的拍摄/监看角色。

B 在每次发起控制连接前产生不可预测的 `sessionId`，并在升级后的 5 秒内通过
第一条 `session.hello` 发送；A 把它绑定到当前已配对 Aware 对端和控制连接，
随后在 `session.accepted` 中原样回显。`sessionId` 用于会话路由和防止旧消息
串入，不是长期身份或秘密。MVP 的初始控制连接依赖 Aware 链路的认证、加密和
对端绑定；后续版本可协商 TLS，但不得把公网 PKI 或账号系统作为 v1 的隐含依赖。

A 在 `session.accepted` 中另发不可预测的 `accessToken`（16–128 个
base64url 字符）。它只授权当前 Aware 数据路径上的
`GET /v1/photos/*`：

```http
Authorization: Bearer <accessToken>
```

服务端应常量时间比较令牌。令牌不得写日志、持久化或在其他网络接口使用；
WebSocket 断开、会话结束或能力丢失时必须立即吊销。它不能用于初始 WebSocket
认证，因为它本身是在该通道协商成功后才安全交付的。

## 控制消息

WebSocket 只接受完整的 UTF-8 JSON 文本消息。每条消息均有四个必需字段：

```json
{
  "type": "heartbeat.ping",
  "requestId": "ping-42",
  "protocolVersion": "1.0",
  "payload": {"sentAtMs": 123456789}
}
```

- `type` 决定 payload；未知消息类型不是“可选字段”，必须以
  `UNSUPPORTED_MESSAGE_TYPE` 拒绝。
- `requestId` 是发送方方向内的幂等键，格式为 1–64 个
  `[A-Za-z0-9._~-]` 字符。响应（如 `session.accepted`、`heartbeat.pong`
  或 `error`）回显请求的 ID；主动事件产生新的 ID。两个方向使用独立账本。
- `protocolVersion` 为 `MAJOR.MINOR`。v1 实现接受其理解的 `1.x` 可选扩展，
  明确拒绝其他主版本。
- 所有层级的未知可选字段必须忽略并保留转发安全性；已知字段仍必须做类型、
  范围和状态校验。

### 消息及方向

| `type` | 方向 | 关键 payload / 语义 |
| --- | --- | --- |
| `session.hello` | B→A | monitor 角色、会话 ID、显示/视口/方向、HEVC 上限、成片开关 |
| `session.accepted` | A→B | capture 角色、会话级文件令牌、选定预览、RTP/RTCP 与照片 HTTP 端点 |
| `preview.start` | B→A | 以已协商 `configId` 开流 |
| `preview.stop` | 双向 | 停流原因；控制失效时不等待确认 |
| `preview.reconfigure` | A→B | 新配置及原因；参数集和 IDR 是切换边界 |
| `preview.tierRequest` | B→A | 有限降档建议，不承诺连续自适应 |
| `keyframe.request` | B→A | 丢包、解码重置、启动或重配置时请求 IDR |
| `photo.receivePreference` | B→A | 会话中同步“接收成片”开关 |
| `photo.captured` | A→B | 静态管线完成及 A 本地保存结果 |
| `photo.available` | A→B | 可拉取成片的元数据及生存期；开关关闭时禁止发送 |
| `photo.transferResult` | B→A | `saved`、`failed` 或 `cancelled`；失败必须有错误码 |
| `heartbeat.ping/pong` | 双向 | 控制活性与粗略 RTT |
| `error` | 双向 | 稳定错误码、面向用户/日志的短消息、是否可重试 |
| `session.end` | 双向 | 会话终止，终止后不接受其他消息 |

完整字段和范围见
[`schemas/v1/control-message.schema.json`](schemas/v1/control-message.schema.json)。
Schema 使用 JSON Schema Draft 2020-12；其中 `photo.available.metadata` 的相对
`$ref` 必须相对于该 schema 所在目录离线解析。

`session.accepted.photoEndpoint` 使文件连接保持为独立 TCP 通道。常规情况使用
`{"port": <1...65535>}`，其主机就是当前已配对 Aware 对端；无法在现有数据路径
追加连接的平台可使用 `{"serviceName":"_remote-photo._tcp"}`，两端再针对同一
已配对设备发布/订阅这个声明过的备用 Aware service。两种字段必须且只能出现
一个，客户端不得在普通 DNS、局域网或蜂窝网络解释它们。

`session.accepted.rtp.rtpPort` 与 `rtcpPort` 都是 **A 在当前 Aware 对端上监听的
UDP 端口**；`destinationAddress` 也描述 A，而不是 B。B 必须用绑定到同一 Aware
数据路径的两个独立 UDP socket 主动连接这两个端口。为使按 flow 接受 UDP 的平台
在首帧前获得 B 的返回端点，B 在 RTP socket ready 后先发送且只发送一次四字节
ASCII `RCP1` 探测报文；A 在 RTP 解析器之外消费它，随后从同一 flow 向 B 回送
RTP。B 在 RTCP socket ready 后立即发送首个合法 RR 或 PLI；这同时建立反馈 flow。
`RCP1` 不是 RTP payload，B 不得把它交给解包器，A 也不得把其他非 RTP 数据当作
探测报文。端口、地址或 flow 都不得在会话外复用。

协商结果中的编码显示宽高比为
`(widthPx × sampleAspectRatio.width) : (heightPx × sampleAspectRatio.height)`；
当前常见编码使用 `1:1` 方形像素，但两端不得省略或自行猜测该字段。

### 解析、资源与超时

网络层必须尽可能在分配/重组之前应用上限；参考实现还会在解析后复核：

| 项目 | v1 上限 |
| --- | ---: |
| 单条重组后的控制消息 | 65,536 UTF-8 bytes |
| JSON 嵌套深度 | 16 |
| JSON 总节点数 | 4,096 |
| 单对象成员数 | 128 |
| 单数组元素数 | 256 |
| 字符串 / 对象键 | 4,096 / 128 UTF-8 bytes |
| 数字文本 | 64 字符 |
| 重复请求账本 | 1,024 条、120 秒 TTL |

必须拒绝无效 UTF-8、重复 JSON key、`NaN`/`Infinity`、孤立 surrogate、超限
整数以及类型不符（尤其 JSON boolean 不能当 integer）。WebSocket 二进制消息
不属于 v1。

首次 hello 超时为 5 秒；普通命令响应超时建议 5 秒。空闲时每 2 秒发一次
heartbeat，连续 3 次没有有效 pong（约 6 秒）视为控制失效。实现可在前后台切换
时放宽网络定时器，但不能在控制失效后继续无人管理的预览或文件传输；检测到
断开后应在 1 秒内停止这些流量。

同一方向再次出现相同 `requestId` 时：

1. 若规范化后的完整消息相同，返回第一次已缓存的响应，不重复副作用；
2. 若消息内容不同，返回 `DUPLICATE_REQUEST_CONFLICT`；
3. 账本过期后可作为新请求处理。

### 线错误码

`error.payload.code` 至少使用以下稳定值；解析器的更细内部错误可归并到这些线
错误，但不得把堆栈、路径或令牌发给对端。

| 错误码 | 含义 |
| --- | --- |
| `UNSUPPORTED_PROTOCOL_VERSION` | 主版本不兼容 |
| `UNSUPPORTED_MESSAGE_TYPE` | 当前版本未知的必需消息语义 |
| `INVALID_MESSAGE` | JSON、字段、长度或资源限制不合法 |
| `INVALID_STATE` | 消息在当前会话状态不可执行 |
| `DUPLICATE_REQUEST_CONFLICT` | 请求 ID 被用于不同内容 |
| `AUTHENTICATION_FAILED` | 会话/文件令牌无效 |
| `CAPABILITY_UNAVAILABLE` | Wi-Fi Aware、编解码器或权限当前不可用 |
| `PREVIEW_FAILED` | 捕获、编码、发送或解码失败 |
| `PHOTO_NOT_AVAILABLE` | 资源不存在、过期或已确认删除 |
| `PHOTO_TRANSFER_FAILED` | HTTP、存储或照片库写入失败 |
| `INTEGRITY_MISMATCH` | 成片长度或 SHA-256 不符 |
| `RESOURCE_LIMIT` | 输入触发固定资源上限 |
| `TIMEOUT` | 协商、心跳或传输超时 |
| `INTERNAL_ERROR` | 未安全暴露细节的本地故障 |

## 会话状态机

两端使用相同的状态名称和事件。非法转换不修改状态，也不隐式跳过配对步骤。

```text
unpaired --startDiscovery--> discovering --peerSelected--> pairing
pairing --pairingSucceeded--> connecting --transportConnected--> connected
pairing --pairingFailed--> interrupted
connecting --transportFailed--> interrupted
connected --controlLost--> interrupted --retry--> discovering
unavailable --capabilityRestored--> unpaired
任意非 ended 状态 --end--> ended
任意非 unavailable/ended 状态 --capabilityLost--> unavailable
```

`ended` 是终态。角色只在进入本次会话前选择，状态机不含角色互换事件。
规范转换和非法序列见 `reference/state_machine.py` 与
`vectors/v1/session-state.json`。

## HEVC RTP（RFC 7798）

v1 使用 90 kHz RTP 时钟和动态 payload type `96..127`。一次 HEVC access unit
内所有包具有相同 timestamp/SSRC；序号逐包递增并按 16 位回绕；仅最后一个包
设置 marker。30 fps 恒定帧率通常每帧增加 3,000，但采集端应以实际采集时间
生成时间戳而不是假定固定到达间隔。

协商的 `maxRtpPacketSize` 指**完整 RTP 包**大小，不含 UDP/IP 头。发送端应从
实际 path MTU 扣除网络头（IPv6+UDP 通常 48 bytes）得到该值，禁止依赖 IP
分片。

v1 的 RFC 7798 子集为非交织模式：

- 小 NAL unit 可直接作为 Single NAL payload；
- 两个以上相邻小 NAL 可放入 AP（NAL type 48），每项使用 16-bit 网络序长度；
  AP header 的 LayerId/TID 必须分别取内部 NAL 的最低值；
- 超限 NAL 去掉原始 2-byte NAL header 后放入 FU（type 49），正确设置 S/E 和
  FuType；
- 不协商 DONL、DOND、PACI（type 50）、RTP header extension、padding 或 CSRC。

会话开始、任何编码配置改变和 IDR 前必须依次提供 VPS/SPS/PPS（可聚合成一个
AP）。分辨率改变先发 `preview.reconfigure`，然后以新参数集+IDR 为唯一切换
边界。编码器禁用 B 帧，限制参考帧和 GOP，并周期性产生 IDR。

接收端以 marker 识别 access-unit 末尾，可在严格窗口内按序号重排。实时实现的
建议窗口是最多 64 包或 50 ms（先到者为准）；迟到帧直接丢弃。参考
depacketizer 的绝对防御上限为每 AU 4,096 RTP 包、1,024 NAL、单 NAL 16 MiB、
单 AU 64 MiB。序号缺口、重复包、混合 timestamp/SSRC/PT、残缺 FU 或多个 marker
会使整个 AU 被拒绝；不要等待重传阻塞后续帧，而应限频请求新关键帧。

`vectors/v1/hevc-rtp.json` 固定 Single、AP、FU、乱序和 16-bit 序号回绕的逐字节
结果。其中 64-byte RTP 包仅用于迫使小测试数据走 FU；真实协商仍遵守 schema
中至少 256 bytes 的范围和实际 path MTU。

## RTCP Receiver Report 与 PLI

B 向 A 定期发送 RTCP v2 Receiver Report（PT=201），报告 negotiated media
SSRC 的：

- 8-bit fixed-point `fraction lost`（比例为值除以 256）；
- signed 24-bit cumulative loss；
- extended highest sequence；
- 90 kHz 单位的 interarrival jitter；
- LSR 和 DLSR（DLSR 比例为值除以 65,536 秒）。

A 若记录了对应 Sender Report 的 compact NTP 到达值，可按 RFC 3550 的
`A - LSR - DLSR` 计算 RTT。MVP 只需记录这些指标，不据此实现连续自适应。

丢帧、解码器重置、启动或重配置时，B 可发送 RFC 4585 PSFB PLI
（FMT=1、PT=206、无 FCI）请求 IDR。除明确重配置边界外，建议每个 media SSRC
最多每 500 ms 发一个 PLI，防止畸形链路形成反馈风暴。

参考实现接受单个或由 RR/PLI 组成的复合 datagram，最大 1,500 bytes、16 个
subpacket，必须 32-bit 对齐且 length 精确。v1 参考子集拒绝 padding、错误版本、
零/未协商 SSRC 和其他 packet type。`vectors/v1/rtcp.json` 包含 RR 指标、signed
24-bit 值、PLI、复合报文、长度及 SSRC 反例。

## 成片传输与完整性

只有 B 最新的 `photo.receivePreference.enabled` 为 `true` 时，A 才创建会话内
`photoId`、发布资源并发送 `photo.available`。元数据 schema 位于
`schemas/v1/photo-metadata.schema.json`，必需字段是：

```json
{
  "photoId": "photo_0123456789ABCDEF",
  "fileName": "IMG_0001.HEIC",
  "mimeType": "image/heic",
  "byteSize": 28,
  "widthPx": 4032,
  "heightPx": 3024,
  "sha256": "ad2978fb96ca33695ff82081c97814a8d111fc652fdb975432a9cb36ee6b00ac",
  "downloadPath": "/v1/photos/photo_0123456789ABCDEF"
}
```

- `photoId` 为 16–128 个 base64url 字符，只在当前会话有效；
- `fileName` 必须是单个安全路径组件；接收端不把它直接拼接到任意目录；
- v1 MIME 白名单为 JPEG、HEIC、HEIF 和 DNG；HTTP `Content-Type` 必须一致；
- `byteSize` 范围为 1 byte–512 MiB，HTTP `Content-Length` 必须完全一致；
- `sha256` 是最终文件 bytes 的 64 位小写十六进制 SHA-256；
- `downloadPath` 必须与 `photoId` 精确组成 `/v1/photos/{photoId}`。

HTTP 行为：有效令牌和资源返回 `200` 流式 body；令牌错误返回 `401`；不存在或
不属于本会话返回 `404`；已过期返回 `410`。禁止 Range/断点续传；带 Range 的
v1 请求返回 `416`。响应与预览使用独立 TCP/UDP 通道，发送调度必须给控制和
预览更高优先级。文件连接建议设置 10 秒 idle timeout；允许在
`expiresInSeconds`（1–3,600 秒）内做有限次数的整文件重试。

B 以 64 KiB 左右的有界 chunk 写入独占创建的临时文件，同时累计长度和
SHA-256；严格读到声明长度后还要检查没有额外 byte。只有两项都相符才调用平台
照片库保存，并发送 `photo.transferResult: saved`。失败时删除本次调用创建的
临时文件，不能删除预先存在的路径。成功确认、过期、控制断开或会话结束后，A
立即删除发布资源。

## 安全与资源原则

- 所有网络值在用于分配、文件路径、端口、SSRC、数组索引或状态转换前校验；
- 随机会话 ID、文件令牌、SSRC 和初始 RTP sequence 使用系统 CSPRNG；
- 不依据固定 IP、MAC 或永久 peer handle 识别设备；
- 日志不得包含 access token、照片内容或完整敏感元数据；
- 解析失败只丢弃当前消息/帧/资源并给出稳定错误，不崩溃、不无限分配、不无限
  延长缓冲；
- 文件 socket 必须配置读超时；纯流校验器本身不能替代网络超时；
- WebSocket 失效即撤销控制权、停止 RTP/RTCP 和 HTTP body，并清理会话资源。

## 共享向量与参考测试

两端的协议单元测试应直接读取这些文件，不复制数据到各自测试源码：

| 向量 | 覆盖 |
| --- | --- |
| `control-messages.json` | 全部 v1 消息、未知可选字段、版本/字段/JSON 反例、文件令牌 |
| `session-state.json` | 正常连接、断连重试、能力变化、终态与非法转换 |
| `hevc-rtp.json` | RFC 7798 Single/AP/FU、marker、乱序、丢包、回绕 |
| `rtcp.json` | RR 指标、RTT 字段、PLI、复合包和畸形长度/SSRC |
| `photo-integrity.json` | 元数据限制、逐 byte 长度与 SHA-256 结果 |

在仓库根目录直接运行（不需要 pip 包）：

```sh
python3 protocol/run_reference_tests.py
```

也可以单独运行向量相关模块：

```sh
python3 -m unittest protocol.tests.test_hevc_rtp
python3 -m unittest protocol.tests.test_rtcp
```

参考实现是跨平台行为判定器，不是移动端网络服务器。Swift/Kotlin 实现可采用
各自系统 API，但相同向量必须产生相同 bytes、状态和错误分类。
