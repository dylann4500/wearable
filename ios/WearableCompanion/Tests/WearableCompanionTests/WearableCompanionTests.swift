import XCTest
@testable import WearableCompanion

final class WearableCompanionTests: XCTestCase {
    func testMockRecordingHasCompletedResult() throws {
        let recording = try XCTUnwrap(MockData.recordings.first)

        XCTAssertEqual(recording.status, .complete)
        XCTAssertNotNil(recording.result?.summary)
    }
}
