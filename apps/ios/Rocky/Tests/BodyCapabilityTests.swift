import XCTest

@testable import Rocky

/// The tools offered have to match what the body can actually answer. A model holding a tool that
/// cannot work will use it and then explain, confidently, that it did something it did not do.
///
/// There is one body now (apps/robot/device/rocky_agent.py, the autonomous loop), so the baked
/// config already describes it exactly and needs no edit when a robot is present. The only case
/// left to handle is its absence.
final class BodyCapabilityTests: XCTestCase {
    private func config() -> Data {
        let session: [String: Any] = [
            "instructions": "You are Someone. It moves itself.",
            "tools": [
                ["type": "function", "name": "stop_robot"],
                ["type": "function", "name": "get_robot_state"],
                ["type": "function", "name": "set_robot_mood"],
                ["type": "function", "name": "robot_gesture"],
                ["type": "function", "name": "robot_routine"],
            ],
            "tool_choice": "auto",
        ]
        return try! JSONSerialization.data(withJSONObject: ["session": session])
    }

    private func toolNames(_ data: Data) -> [String] {
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let session = root["session"] as! [String: Any]
        return (session["tools"] as! [[String: Any]]).map { $0["name"] as! String }
    }

    private func instructions(_ data: Data) -> String {
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (root["session"] as! [String: Any])["instructions"] as! String
    }

    func testNoBodyDropsEveryTool() {
        let none = OpenAIRealtimeMinter.withoutRobotBody(config())

        XCTAssertTrue(toolNames(none).isEmpty)
        XCTAssertTrue(instructions(none).contains("NOT CONNECTED RIGHT NOW"))
    }

    /// The persona itself still comes from session.ts. Only the body claim is overridden, and it
    /// has to land last to win.
    func testTheCharacterSurvivesLosingItsBody() {
        let text = instructions(OpenAIRealtimeMinter.withoutRobotBody(config()))

        XCTAssertTrue(text.hasPrefix("You are Someone."))
        XCTAssertTrue(text.contains("not moving"), "an absent body is not quietly still, it is absent")
    }

    func testAnUnrecognisableConfigIsLeftAlone() {
        let odd = Data("{\"nope\":1}".utf8)

        XCTAssertEqual(OpenAIRealtimeMinter.withoutRobotBody(odd), odd)
    }
}
