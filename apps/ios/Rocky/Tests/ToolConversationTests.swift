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
}
