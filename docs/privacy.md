# Privacy and data handling

The application has no accounts, analytics, cloud API, relay, telemetry, advertisements, or internet dependency. Camera frames, final photos, peer descriptors, and performance data remain on the two paired devices.

- Camera access is requested only after selecting the capture role.
- Photo-library add permission is requested only immediately before the first save.
- Nearby Wi-Fi permission on Android is used only for Wi-Fi Aware discovery and data paths, and is declared as not deriving location.
- Session identifiers, bearer tokens, peer handles, endpoints, and photo resources are ephemeral and cleared when control connectivity ends.
- Diagnostic logs must not contain bearer tokens, image bodies, stable hardware identifiers, or raw peer addresses.
