import XCTest
@testable import WearableCompanion

final class WearableCompanionTests: XCTestCase {
    func testMockRecordingHasCompletedResult() throws {
        let recording = try XCTUnwrap(MockData.recordings.first)

        XCTAssertEqual(recording.status, .complete)
        XCTAssertNotNil(recording.result?.summary)
    }

    func testBLEDataPacketParsesOffsetAndPayload() throws {
        let data = Data([
            0xA0, 0x00, 0x00, 0x00,
            0x03, 0x00,
            0x52, 0x49, 0x46,
        ])

        let packet = try XCTUnwrap(BLEDataPacket(data: data))

        XCTAssertEqual(packet.offset, 160)
        XCTAssertEqual(packet.payload, Data([0x52, 0x49, 0x46]))
    }

    func testBLEDataPacketRejectsInvalidLength() {
        let data = Data([
            0x00, 0x00, 0x00, 0x00,
            0x04, 0x00,
            0x01, 0x02,
        ])

        XCTAssertNil(BLEDataPacket(data: data))
    }

    func testCRC32MatchesStandardVector() {
        XCTAssertEqual(
            CRC32.checksum(data: Data("123456789".utf8)),
            0xCBF4_3926
        )
    }
}
