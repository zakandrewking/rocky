import XCTest

@testable import Rocky

/// The no-robot path: when discovery finds nothing, the app is still a full voice Rocky (what
/// apps/desktop is), so the session it mints must not still be advertising movement tools it
/// cannot honour. No device or network needed -- this is a pure transform of the baked config.
final class RealtimeSessionConfigTests: XCTestCase {
    private func config(tools: [[String: Any]], instructions: String) -> Data {
        let root: [String: Any] = [
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "tools": tools,
                "tool_choice": "auto",
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func session(of data: Data) -> [String: Any] {
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["session"] as! [String: Any]
    }

    func testDropsBodyToolsWhenThereIsNoRobot() {
        let input = config(
            tools: [["type": "function", "name": "robot_gesture"], ["type": "function", "name": "stop_robot"]],
            instructions: "You are Rocky."
        )

        let stripped = session(of: OpenAIRealtimeMinter.withoutRobotBody(input))

        XCTAssertEqual((stripped["tools"] as! [Any]).count, 0)
        XCTAssertEqual(stripped["tool_choice"] as! String, "none")
    }

    func testCorrectsTheBodyContextSoRockyDoesNotPromiseABodySheHasNot() {
        let input = config(tools: [], instructions: "You are Rocky. It moves itself.")

        let instructions = session(of: OpenAIRealtimeMinter.withoutRobotBody(input))["instructions"] as! String

        // Kept, not replaced: the persona itself still comes from session.ts. Only the body
        // claim is overridden, and it has to land last to win.
        XCTAssertTrue(instructions.hasPrefix("You are Rocky. It moves itself."))
        XCTAssertTrue(instructions.contains("NOT CONNECTED RIGHT NOW"))
    }

    func testLeavesAnUnrecognisableConfigAlone() {
        let notOurShape = Data("{\"something\":\"else\"}".utf8)

        XCTAssertEqual(OpenAIRealtimeMinter.withoutRobotBody(notOurShape), notOurShape)
        XCTAssertEqual(OpenAIRealtimeMinter.withoutRobotBody(Data("not json".utf8)), Data("not json".utf8))
    }

    func testBodySessionUpdatesRestoreAndRemoveToolsWithoutReplacingTheConversation() throws {
        let connected = try XCTUnwrap(OpenAIRealtimeMinter.bodySessionUpdate(hasBody: true))
        let voiceOnly = try XCTUnwrap(OpenAIRealtimeMinter.bodySessionUpdate(hasBody: false))
        XCTAssertEqual(connected["type"] as? String, "session.update")

        let connectedSession = try XCTUnwrap(connected["session"] as? [String: Any])
        let voiceOnlySession = try XCTUnwrap(voiceOnly["session"] as? [String: Any])
        XCTAssertEqual(connectedSession["type"] as? String, "realtime")
        XCTAssertEqual((connectedSession["tools"] as? [Any])?.count, 8)
        XCTAssertEqual(connectedSession["tool_choice"] as? String, "auto")
        XCTAssertEqual((voiceOnlySession["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(voiceOnlySession["tool_choice"] as? String, "none")
        XCTAssertTrue(
            (voiceOnlySession["instructions"] as? String)?.contains("NOT CONNECTED RIGHT NOW") == true
        )
    }

    func testTheBakedCatalogKeepsRockyAsItsOnlyFixedPersonality() throws {
        let data = try XCTUnwrap(OpenAIRealtimeMinter.bakedSessionData())
        let instructions = session(of: data)["instructions"] as? String

        XCTAssertTrue(instructions?.contains("You are Rocky") == true)
    }
}
