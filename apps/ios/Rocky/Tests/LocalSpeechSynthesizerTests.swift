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

    func testElevenLabsModelSelectionKeepsV3EasyToRestore() {
        XCTAssertEqual(ElevenLabsSpeechModel.configured("eleven_flash_v2_5"), .flashV25)
        XCTAssertEqual(ElevenLabsSpeechModel.configured("eleven_v3_conversational"), .conversationalV3)
        XCTAssertEqual(ElevenLabsSpeechModel.configured(nil), .conversationalV3)
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

    func testParsesElevenLabsFlashNestedErrorsWithoutLeakingTheBody() {
        let data = Data(
            #"{"detail":{"status":"quota_exceeded","message":"No credits"},"private":"secret"}"#.utf8
        )
        XCTAssertEqual(
            ElevenLabsFlashSpeech.errorMessage(from: data),
            "No credits"
        )
    }
}
