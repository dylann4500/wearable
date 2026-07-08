# WearableCompanion

SwiftUI MVP shell for the iOS companion app.

Run the package from Xcode by opening this folder and selecting the `WearableCompanion` executable scheme. The code is intentionally small and service-oriented so it can later move into a normal iOS app target without changing the feature views.

The app currently includes:

- recording list/status UI backed by the existing FastAPI API shape.
- manual audio upload for phone-side testing.
- detail UI for metrics and transcript turns.
- device pairing/provisioning design for the XIAO ESP32 prototype.
- settings for backend URL and production token/security boundaries.

See `Docs/ProductShape.md` for the architecture and connectivity decisions.
