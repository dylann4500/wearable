# Wearable Companion iOS App

Open `WearableCompanionApp.xcodeproj` in Xcode to run the app on Simulator or a physical iPhone.

Before running on a phone:

1. Select the `WearableCompanion` target.
2. Open `Signing & Capabilities`.
3. Choose your Apple development team.
4. Change the bundle identifier from `com.example.WearableCompanion` if Xcode asks for a unique value.

Without a backend, the app still opens with mock recording data and the device/pairing design screens. Backend-backed refresh and upload actions will show an error until `Settings > Backend URL` points at a reachable FastAPI server.
