# Real-device acceptance plan

Wi-Fi Aware, the hardware codecs, camera processing, orientation behavior, and photo-library writes must be validated on physical devices. Simulators do not qualify for these checks.

## Test matrix

Record device model, OS build, Wi-Fi Aware capability, camera format, HEVC profile/level, negotiated resolution, average bitrate, observed frame rate, and latency for each run.

1. iOS capture to Android monitor.
2. Android capture to iOS monitor.
3. iOS to iOS, when two supported iOS devices are available.
4. Android to Android, when two supported Android devices are available.

Repeat every direction with the devices disconnected from infrastructure Wi-Fi, mobile data disabled, and no hotspot or router present. Keep Wi-Fi radio enabled.

## Pairing and recovery

1. Remove the existing peer pairing and launch both apps.
2. Confirm an unsupported device stops before pairing and shows the detected reason.
3. Select complementary application roles.
4. Pair through system UI, verify the selected peer on both devices, and establish the data path.
5. End and reconnect without repairing.
6. During preview, disable Wi-Fi, move out of range, and terminate either app in separate runs.
7. Verify the other side reports interruption, stops preview and photo traffic promptly, and offers retry/end.

Capture system logs and timestamps for failures. Never include photo contents in bug reports unless the tester explicitly chose a synthetic fixture.

## Preview quality and latency

1. Display a millisecond timer in the capture scene and place both device displays in one 120/240 fps reference recording.
2. After 30 seconds of warm-up, record at least 60 seconds.
3. Sample at least 30 readable timer pairs across the run. Report median, p95, and maximum glass-to-glass delta; the pass target is median and p95 below 200 ms on a stable near-range link.
4. Confirm 30 fps and approximately 10 Mbit/s from sender/receiver metrics.
5. Move a high-contrast object quickly through frame and confirm packet loss drops damaged frames instead of building delay.
6. Rotate capture and monitor devices through all supported orientations. Verify matching orientation, no stretching, center crop, and safe-area handling.

## Still-photo transfer

1. With receive enabled, capture a detailed scene. Verify capture saves locally, monitor receives the final processed still, byte length and SHA-256 match, and monitor saves it.
2. Compare dimensions and metadata with the capture file to prove it is not a preview frame.
3. Capture while previewing fast motion and verify preview stays responsive during transfer.
4. Disable receive during the session, take another photo, and verify no resource is advertised or saved on the monitor.
5. Exercise permission denial, low storage, connection loss mid-download, checksum mismatch with a test fixture, retry limit, and resource expiry.

## Result record

Store one Markdown result per run under `artifacts/device-tests/YYYY-MM-DD-<direction>.md` locally. Attach only sanitized summaries to source control; `artifacts/` is ignored because device logs can contain identifiers.
