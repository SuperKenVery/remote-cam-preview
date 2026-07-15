# Architecture

Remote Cam Preview is a symmetric two-device application. A role is selected for each session, while both installed applications retain the ability to publish and subscribe to the same Wi-Fi Aware service.

## Trust and transport boundary

- Wi-Fi Aware performs user-mediated pairing, peer authentication, encryption, discovery, and creation of the scoped IP data path.
- No socket may bind to an ordinary Wi-Fi, cellular, VPN, or wildcard route. iOS connections are created from a `WAEndpoint`; Android sockets are created with the `SocketFactory` or bound with the `Network` returned by the Aware network callback.
- The capture role is the application server for the session. The monitor role initiates control and photo requests. Wi-Fi Aware publish/subscribe roles are negotiated separately and must not be inferred from the application role.
- Every connection uses a random session identifier and bearer token. Both are invalid after control-channel loss or session termination.

Android 14–16 exposes NAN Pairing setup/verification and cached peer aliases, but does not expose the cached NPK/NIK as the PMK/PMKID required by `WifiAwareNetworkSpecifier`. The Android transport therefore accepts only an authenticated, per-session `SecureDataPathCredential`; without a platform/vendor-supported cross-device bootstrap it reports a blocked secure-data-path state. It never substitutes an open NDP, a fixed PSK, or a credential derived from public discovery metadata. This is a real-device interoperability gate, not a condition that protocol or emulator tests can waive.

iOS 最低支持 26.4。控制连接建立后，RTP、RTCP 与照片通道统一通过 scoped additional connections 和协商端口复用已配对对端；不保留 iOS 26.0–26.3 的额外 service-specific 分支。

## Logical channels

| Channel | Transport | Priority | Owner |
| --- | --- | --- | --- |
| Control | HTTP/1.1 upgrade to WebSocket over TCP | Highest | Capture listens; monitor connects |
| Preview | RTP/RTCP over UDP | High, latency-first | Capture listens; monitor connects, primes the flow, receives RTP, and sends RTCP |
| Photo | Streaming HTTP GET over a separate TCP connection | Background | Monitor pulls from capture |

Control messages are versioned JSON and capped at 64 KiB. RTP uses a 90 kHz clock, a random SSRC, and RFC 7798 single-NAL, aggregation-packet, or fragmentation-unit payloads sized below the path MTU. Photo bodies are streamed through temporary files and become visible to the photo library only after length and SHA-256 verification.

The RTP and RTCP ports advertised by capture are capture-side UDP listeners. Monitor connects both sockets on the same scoped Aware path, sends the `RCP1` path probe on RTP and an initial valid RTCP report, then receives RTP replies on that established flow. This ownership rule avoids assigning the same fields opposite meanings on Swift and Kotlin.

## Session state

The shared state vocabulary is:

`unpaired -> searching -> pairing -> connecting -> connected`

From any active state, capability loss moves the session to `unavailable`, transport loss to `interrupted`, and an explicit close to `ended`. Retry starts a fresh session and therefore a fresh session ID, token, peer handle, RTP sequence space, and photo resource table.

## Media path

The monitor advertises native screen pixels, current safe viewport, orientation, and HEVC decoding limits. The capture side selects the largest encoder-supported dimensions that cover the viewport without changing aspect ratio, then uses center crop at presentation. The initial target is 30 fps and 10 Mbit/s. Encoders disable frame reordering and B-frames, constrain the GOP, and send VPS/SPS/PPS at startup and before IDR boundaries.

Still images never come from the preview encoder. AVFoundation `AVCapturePhotoOutput` and CameraX `ImageCapture` produce the final file, which is saved locally before optional publication to the monitor.

## Source layout

- `protocol/`: normative v1 schemas, shared vectors, and a dependency-free reference implementation.
- `ios/`: iOS 26 SwiftUI application and XCTest targets.
- `android/`: Kotlin/Compose Android application and JVM tests.
- `docs/`: architecture, privacy, and repeatable real-device validation procedures.

Hardware-dependent integration is intentionally behind small interfaces so parsers, state transitions, negotiation, packetization, and integrity checks can run in CI without a camera or Wi-Fi Aware radio.
