# Wearable Companion iOS App

Open `WearableCompanionApp.xcodeproj` in Xcode to run the app on Simulator or a physical iPhone.

Before running on a phone:

1. Select the `WearableCompanion` target.
2. Open `Signing & Capabilities`.
3. Choose your Apple development team.
4. Change the bundle identifier from `com.example.WearableCompanion` if Xcode asks for a unique value.

Without a backend, verified BLE downloads remain on the phone in `Waiting for
backend` state. For automatic analysis, set `Settings > Backend URL` to a
reachable HTTPS FastAPI deployment, enter the matching device upload token, and
enable the backend. The Insights tab displays the completed backend result; it
does not use mock data at runtime.

For Mac-on-the-same-Wi-Fi development, start the backend with
`HOST=0.0.0.0 ./scripts/run.sh`, then use the Mac's LAN URL such as
`http://192.168.1.42:8000` in Settings. Never use `127.0.0.1` as the backend URL
on a physical iPhone because that address refers to the iPhone itself.
