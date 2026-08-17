import XCTest

@testable import Rocky

@MainActor
final class ToolConversationTests: XCTestCase {
    func testToolFollowupsReturnToThePersonsTopicInsteadOfNarratingMovement() {
        let prompt = RealtimeVoiceSession.toolFollowupPrompt

        XCTAssertTrue(prompt.contains("Continue the person's actual request"))
        XCTAssertTrue(prompt.contains("Tools and body state are silent"))
        XCTAssertTrue(prompt.contains("Do not announce, explain, confirm, recap, or offer movements"))
        XCTAssertTrue(prompt.contains("deliver that content naturally"))
        XCTAssertTrue(prompt.contains("no additional words"))
    }
}
