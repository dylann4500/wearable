import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .recordings
    var backendBaseURL = URL(string: "http://127.0.0.1:8000")!
    var selectedRecordingID: Recording.ID?
    var pairingMode: PairingMode = .bluetoothProvisioning
    var uploadTokenStatus: UploadTokenStatus = .developmentToken
}

enum UploadTokenStatus: String, CaseIterable, Identifiable {
    case developmentToken = "Development token"
    case provisioned = "Provisioned"
    case expired = "Expired"

    var id: String { rawValue }
}
