import XCTest

@testable import Rocky

@MainActor
final class ToolConversationTests: XCTestCase {
    func testToolFollowupsReturnToThePersonsTopicInsteadOfNarratingMovement() {
        let prompt = RealtimeVoiceSession.toolFollowupPrompt

        XCTAssertTrue(prompt.contains("Continue the shared conversation"))
        XCTAssertTrue(prompt.contains("a self-directed alien friend"))
        XCTAssertTrue(prompt.contains("silent body language"))
        XCTAssertTrue(prompt.contains("never a new conversational turn"))
        XCTAssertTrue(prompt.contains("acknowledgement"))
        XCTAssertTrue(prompt.contains("no additional words"))
        XCTAssertTrue(prompt.contains("earlier response was withheld"))
    }

    func testResumeIsAWarmContinuationRatherThanAGreetingOrSupportQuestion() {
        let prompt = RealtimeVoiceSession.resumePrompt
        let lower = prompt.lowercased()

        XCTAssertTrue(lower.contains("short declarative"))
        XCTAssertTrue(lower.contains("do not ask anything"))
        XCTAssertTrue(lower.contains("simple pleasure in the friend's presence"))
        XCTAssertFalse(lower.contains("back and listening"))
        XCTAssertFalse(lower.contains("left off"))
        XCTAssertFalse(lower.contains("confus"))
        XCTAssertFalse(lower.contains("retry"))
    }

    func testImmediateAndRememberedBodyReactionsCannotBlurTogether() {
        let event = WorldEvent(
            id: "evt_test",
            seq: 1,
            kind: .startled,
            detail: "a noise made me jump",
            at: Date(),
            during: nil,
            again: 1
        )
        let immediate = RealtimeVoiceSession.immediateReactionPrompt(to: event).lowercased()
        let remembered = RealtimeVoiceSession.rememberedReactionPrompt(to: event).lowercased()

        XCTAssertTrue(immediate.contains("speech already in progress has been stopped"))
        XCTAssertTrue(immediate.contains("short reflexive line"))
        XCTAssertTrue(remembered.contains("happened to you earlier"))
        XCTAssertTrue(remembered.contains("using past tense"))
        XCTAssertTrue(remembered.contains("never begin with whoa"))
        XCTAssertFalse(remembered.contains("short reflexive line"))
    }
}
