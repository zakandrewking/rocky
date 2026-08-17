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
        XCTAssertEqual((connectedSession["tools"] as? [Any])?.count, 5)
        XCTAssertEqual(connectedSession["tool_choice"] as? String, "auto")
        XCTAssertEqual((voiceOnlySession["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(voiceOnlySession["tool_choice"] as? String, "none")
        XCTAssertTrue(
            (voiceOnlySession["instructions"] as? String)?.contains("NOT CONNECTED RIGHT NOW") == true
        )
    }

    /// The config the app actually ships is generated at build time, so a change to session.ts
    /// or the generate script that broke its shape would otherwise only show up on a real device.
    /// Deliberately character-agnostic: which character is baked in is a build-time choice, and
    /// this asserts the shape holds whoever it is.
    func testTheBakedConfigIsPresentAndHasTheRobotTools() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "RealtimeSessionConfig", withExtension: "json"),
            "RealtimeSessionConfig.json is missing -- build with apps/ios/scripts/generate.sh"
        )
        let baked = session(of: try Data(contentsOf: url))

        let instructions = baked["instructions"] as! String
        XCTAssertTrue(instructions.contains("You are "), "a character has to say who it is")
        // Conduct is shared across characters; a build missing it would be a real safety gap.
        XCTAssertTrue(instructions.contains("Never tell a child to smell"))

        // Exactly what apps/robot/device/rocky_agent.py answers to. The steering tools went with
        // the deprecated motion agent; a config still advertising them would have Rocky offering
        // to drive a body that drives itself.
        let names = (baked["tools"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertEqual(
            names,
            ["stop_robot", "get_robot_state", "set_robot_mood", "robot_gesture", "robot_routine"]
        )

        let routine = (baked["tools"] as! [[String: Any]]).first { $0["name"] as? String == "robot_routine" }
        XCTAssertNotNil(routine)
        XCTAssertTrue(instructions.contains("BODY LANGUAGE IS SILENT"))
        XCTAssertTrue(instructions.contains("call robot_routine once with the whole sequence"))

        // Whether the model speaks or only writes is the character's choice, and the app reads it
        // back from here to decide whether to run a synthesiser at all.
        let modalities = baked["output_modalities"] as! [String]
        XCTAssertTrue(modalities == ["audio"] || modalities == ["text"], "got \(modalities)")
    }
}
