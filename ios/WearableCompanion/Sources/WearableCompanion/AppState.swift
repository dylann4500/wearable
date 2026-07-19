import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .recordings
    var backendBaseURL = URL(string: "http://192.168.4.97:8000")!
    var isBackendEnabled = true
    var selectedRecordingID: Recording.ID?
    var pairingMode: PairingMode = .bluetoothProvisioning
    var uploadTokenStatus: UploadTokenStatus = .developmentToken
    var deviceUploadToken = "dev-device-token"
}

enum UploadTokenStatus: String, CaseIterable, Identifiable {
    case developmentToken = "Development token"
    case provisioned = "Provisioned"
    case expired = "Expired"

    var id: String { rawValue }
}
