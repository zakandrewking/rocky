import XCTest
@testable import Rocky

final class ConversationOutputGateTests: XCTestCase {
    func testLatePausedResponseIsCancelledAndRemainsSuppressedAfterResume() {
        var gate = ConversationOutputGate()
        XCTAssertEqual(gate.decision(type: "response.created", responseID: "late", blocked: true), .cancel("late"))
        XCTAssertEqual(gate.decision(type: "response.output_text.delta", responseID: "late", blocked: false), .ignore)
        XCTAssertEqual(gate.decision(type: "response.done", responseID: "late", blocked: false), .ignore)
        XCTAssertEqual(gate.decision(type: "response.created", responseID: "new", blocked: false), .process)
        XCTAssertEqual(gate.decision(type: "response.done", responseID: "new", blocked: false), .process)
    }

    func testPauseSuppressesExistingResponseAndLateSpeechEventsButAllowsErrors() {
        var gate = ConversationOutputGate()
        gate.suppress("old")
        XCTAssertEqual(gate.decision(type: "response.done", responseID: "old", blocked: false), .ignore)
        XCTAssertEqual(gate.decision(type: "input_audio_buffer.speech_started", responseID: nil, blocked: true), .ignore)
        XCTAssertEqual(gate.decision(type: "error", responseID: nil, blocked: true), .process)
        XCTAssertFalse(RealtimeVoiceSession.microphoneShouldBeOpen(isPaused: false, backgrounded: true))
    }

    func testStuckQueuedAudioHasFiniteDeadlineWithoutCuttingLongRealBuffers() {
        var progress = PlaybackProgress()
        let now = Date()
        progress.queued(seconds: 0.2, at: now)
        XCTAssertFalse(progress.stalled(at: now.addingTimeInterval(2)))
        XCTAssertTrue(progress.stalled(at: now.addingTimeInterval(4)))
        progress.completed(at: now.addingTimeInterval(4), hasPending: true)
        XCTAssertFalse(progress.stalled(at: now.addingTimeInterval(5)))
        progress.completed(at: now.addingTimeInterval(5), hasPending: false)
        XCTAssertFalse(progress.stalled(at: now.addingTimeInterval(100)))
        progress.queued(seconds: 20, at: now)
        XCTAssertFalse(progress.stalled(at: now.addingTimeInterval(20)))
        XCTAssertTrue(progress.stalled(at: now.addingTimeInterval(22)))
    }

    func testIntroductionCanUseAReacquiredFaceButNeverAnUncertainOrMissingOne() {
        let fresh = FacePresence(kind: .unfamiliar, encounterID: UUID())
        XCTAssertFalse(RealtimeVoiceSession.shouldOfferFaceIntroduction(current: .init(kind: .unknown), quiet: true, conversationAge: 20))
        XCTAssertTrue(RealtimeVoiceSession.shouldOfferFaceIntroduction(current: fresh, quiet: true, conversationAge: 20))
        XCTAssertFalse(RealtimeVoiceSession.shouldOfferFaceIntroduction(current: fresh, quiet: false, conversationAge: 20))
        XCTAssertFalse(RealtimeVoiceSession.shouldOfferFaceIntroduction(current: fresh, quiet: true, conversationAge: 2))
        XCTAssertFalse(RealtimeVoiceSession.shouldOfferFaceIntroduction(current: .init(kind: .multiple), quiet: true, conversationAge: 20))
    }
}
