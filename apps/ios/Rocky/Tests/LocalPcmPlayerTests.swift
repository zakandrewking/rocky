import XCTest

@testable import Rocky

/// Covers the local providers' PCM wire format. Playback itself needs real audio hardware,
/// so the regression that mattered most there -- `stop()` leaving a stale sample cursor, which
/// scheduled the next reply tens of seconds into the future and read as Rocky ignoring you -- is
/// guarded by the comments in LocalPcmPlayer rather than by a test.
final class LocalPcmPlayerTests: XCTestCase {
    func testDecodesSigned16BitLittleEndian() throws {
        // 0, 32767, -32768, -1 as little-endian int16.
        let bytes: [UInt8] = [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0xFF, 0xFF]
        let base64 = Data(bytes).base64EncodedString()

        let samples = try XCTUnwrap(LocalPcmPlayer.decodePCM16LE(base64))

        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 32767.0 / 32768, accuracy: 1e-6)
        XCTAssertEqual(samples[2], -1)
        XCTAssertEqual(samples[3], -1.0 / 32768, accuracy: 1e-6)
    }

    func testRejectsSomethingThatIsNotBase64() {
        XCTAssertNil(LocalPcmPlayer.decodePCM16LE("not base64!!"))
    }

    func testAnEmptyPayloadDecodesToNoSamples() {
        XCTAssertEqual(LocalPcmPlayer.decodePCM16LE("")?.count, 0)
    }

    func testResamplesElevenLabs24kPCMForThe48kAudioEngine() {
        let result = LocalPcmPlayer.resample([0, 1, 0], from: 24_000, to: 48_000)

        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result[0], 0, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(result[2], 1, accuracy: 0.001)
        XCTAssertEqual(result[3], 0.5, accuracy: 0.001)
    }
}
