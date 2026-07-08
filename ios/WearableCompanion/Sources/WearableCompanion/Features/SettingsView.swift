import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(BackendClient.self) private var backend
    @State private var backendURLText = ""

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Backend") {
                TextField("Backend URL", text: $backendURLText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif

                Button("Apply backend URL") {
                    applyBackendURL()
                }

                LabeledContent("Active URL", value: appState.backendBaseURL.absoluteString)
            }

            Section("Device security") {
                Picker("Upload token", selection: $appState.uploadTokenStatus) {
                    ForEach(UploadTokenStatus.allCases) { status in
                        Text(status.rawValue).tag(status)
                    }
                }

                Text("The current FastAPI backend accepts a shared `X-Device-Token`. Production pairing should mint per-device scoped tokens and support rotation or revocation from this screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("MVP boundaries") {
                BoundaryRow(title: "On iPhone", detail: "Pairing, configuration, manual upload, status polling, results review, trend UI, and notifications.")
                BoundaryRow(title: "On wearable", detail: "Audio capture, local SD buffering, BLE setup advertising, optional direct upload, and retry bookkeeping.")
                BoundaryRow(title: "On backend", detail: "Storage, transcription, diarization, ML inference, metrics, authentication, and privacy controls.")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            backendURLText = appState.backendBaseURL.absoluteString
        }
    }

    private func applyBackendURL() {
        guard let url = URL(string: backendURLText), url.scheme != nil else { return }
        appState.backendBaseURL = url
        backend.baseURL = url
    }
}

private struct BoundaryRow: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
