# Verification status

This file separates checks that were actually run from hardware acceptance that still requires the target devices. It is intentionally not a claim that the complete MVP acceptance matrix has passed.

## Automated checks run on 2026-07-11

- `python3 protocol/run_reference_tests.py`: 46/46 passed. This covers strict control JSON, request replay, HEVC/RTP Single/AP/FU and reordering, RTCP RR/PLI, streamed photo integrity, and the shared state machine.
- `nix flake check --no-build path:$PWD`: flake evaluation passed on `aarch64-darwin`.
- Nix `protocol` and `nix-format` check derivations: built successfully.
- iOS `build-for-testing` with Xcode 26.6 / iPhoneOS 26.5 SDK: the app and XCTest targets compiled successfully with signing disabled. The local CoreSimulator service is 1051.54 while Xcode requires 1051.55, so XCTest could not be launched on this host.
- Android Gradle 8.13 `testDebugUnitTest`: 11/11 JVM tests passed against the repository's shared vectors and the parameter-set/IDR access-unit regression.
- Android `assembleDebug`: succeeded and produced the debug APK. Build output remains ignored and is not a source artifact.

## Not yet passed

- No physical iOS/Android Wi-Fi Aware pairing or data path was available in this workspace, so no iOS→Android, Android→iOS, same-platform, camera, codec, Photos/MediaStore, or disconnect timing acceptance result is recorded.
- Android's public NAN Pairing API caches NPK/NIK but does not expose the key material required by the API 36 `WifiAwareNetworkSpecifier`. Cross-platform secure-NDP credential bootstrap therefore remains a platform/vendor real-device gate; the app refuses an open NDP.
- iOS 26.0–26.3 requires extra service-specific Aware data paths for RTP, RTCP, and photos. The Android implementation currently covers the iOS 26.4+ numeric additional-connection path, not those older service endpoints.
- Dynamic orientation/reconfiguration, negotiated capture-format behavior, hardware HEVC parameter-set behavior, 30 fps / 10 Mbit/s stability, photo-versus-preview scheduling, and p50/p95 glass-to-glass latency still require the procedure in `device-test-plan.md`.
- Network.framework's typed WebSocket over a `WAEndpoint` does not expose a request-target setter. Android accepts both `/v1/events` and the Aware-scoped `/` compatibility path, but the actual cross-vendor handshake must be captured on devices.
