import XCTest

@testable import Rocky

final class LocalSpeechSynthesizerTests: XCTestCase {
    func testProviderSelectionIsExplicitAndDefaultsToElevenLabs() {
        XCTAssertEqual(LocalSpeechProvider.configured("elevenlabs"), .elevenlabs)
        XCTAssertEqual(LocalSpeechProvider.configured("ELEVENLABS"), .elevenlabs)
        XCTAssertEqual(LocalSpeechProvider.configured("hume"), .hume)
        XCTAssertEqual(LocalSpeechProvider.configured(nil), .elevenlabs)
        XCTAssertEqual(LocalSpeechProvider.configured("typo"), .elevenlabs)
    }

    func testParsesElevenLabsAudioAndTurnBoundaryFrames() {
        XCTAssertEqual(
            ElevenLabsSpeech.parseServerFrame(#"{"audio":"AQID"}"#),
            .audio("AQID")
        )
        XCTAssertEqual(
            ElevenLabsSpeech.parseServerFrame(#"{"is_final_audio_for_turn":true}"#),
            .turnComplete
        )
    }

    func testParsesElevenLabsErrorsWithoutLoggingWholeFrames() {
        XCTAssertEqual(
            ElevenLabsSpeech.parseServerFrame(#"{"error":"quota exceeded","request_id":"private"}"#),
            .error("quota exceeded")
        )
        XCTAssertNil(ElevenLabsSpeech.parseServerFrame("not json"))
    }
}
