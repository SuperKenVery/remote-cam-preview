# iOS app

The app targets iOS 26 and requires a physical device with Wi-Fi Aware support.
The simulator can build the UI and run protocol tests, but cannot exercise Wi-Fi
Aware, the camera, or hardware HEVC behavior.

Generate and build the project:

```sh
cd ios
xcodegen generate
xcodebuild -project RemoteCamPreview.xcodeproj \
  -scheme RemoteCamPreview \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Before installing on a device, replace the example bundle identifier and select
a development team whose provisioning profile includes the Wi-Fi Aware
entitlement. The capture role provides the application-layer WebSocket, RTP,
RTCP, and photo HTTP endpoints; the monitor role initiates those connections.
All declared services remain publishable and subscribable so the selected,
paired peer can be used for additional Wi-Fi Aware data paths. iOS 26.4 and
later use the additional-connections API; iOS 26.0–26.3 use the declared
`_remote-photo._tcp`, `_remote-preview._udp`, and `_remote-feedback._udp`
services.

The control path uses Network.framework WebSocket text messages, the preview
uses bounded 1200-byte RFC 7798 HEVC/RTP datagrams plus RTCP receiver reports
and PLI, and final photos are streamed over a separate HTTP connection and
verified by length and SHA-256 before Photos insertion.

Initial capture rotation is applied in the AVFoundation output and the monitor
uses aspect-fill rendering. Runtime `preview.reconfigure` for all four device
orientations is not yet wired into the production session, so rotation remains
a real-device acceptance gap rather than a claimed pass.

Interoperability note: Network.framework's typed WebSocket connection does not
expose an HTTP request-target when its destination is a `WAEndpoint`. The iOS
server accepts the framework handshake, but an iOS monitor may therefore use
the framework's default `/` target instead of `/v1/events` when connecting to a
non-Apple server. An Android capture endpoint can safely accept both paths only
on its peer-bound Wi-Fi Aware control listener, with the same five-second
`session.hello` first-message requirement; this direction still requires a
physical-device interoperability test.

`session.accepted.rtp.destinationAddress` is populated from the capture-side
control connection's `localEndpoint` (A), never the monitor endpoint. The iOS
monitor treats that string as diagnostic metadata and derives routable RTP/RTCP
endpoints only from the already paired control peer plus the negotiated ports;
it does not resolve or trust an arbitrary address supplied over JSON.

Pairing and data-path APIs were checked against the iPhoneOS 26.5 SDK shipped
with Xcode 26.6. Service configuration follows Apple's `WiFiAwareServices`
contract and the app requests both `Publish` and `Subscribe` capabilities.
