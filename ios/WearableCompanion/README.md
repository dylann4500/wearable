# WearableCompanion

SwiftUI MVP shell for the iOS companion app.

Run the package from Xcode by opening this folder and selecting the `WearableCompanion` executable scheme. The code is intentionally small and service-oriented so it can later move into a normal iOS app target without changing the feature views.

The app currently includes:

- recording list/status UI backed by the existing FastAPI API shape.
- manual audio upload for phone-side testing.
- detail UI for metrics and transcript turns.
- automatic relay of CRC-verified BLE downloads to the FastAPI analysis pipeline.
- persisted upload/processing state with duplicate-upload protection.
- live deterministic/contextualized ML insight scores, drivers, confidence, and coaching practices.
- device pairing/provisioning design for the XIAO ESP32 prototype.
- settings for backend URL and production token/security boundaries.

See `Docs/ProductShape.md` for the architecture and connectivity decisions.

To run the full phone-relay pipeline, set the reachable HTTPS backend URL and
matching device upload token in Settings, then enable the backend. A completed
BLE download is queued automatically; it does not need to be selected manually.
