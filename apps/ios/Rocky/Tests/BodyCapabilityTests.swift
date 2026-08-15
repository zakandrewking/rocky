import XCTest

@testable import Rocky

/// The tools offered have to match what the body can actually answer. A model holding a tool that
/// cannot work will use it and then explain, confidently, that it did something it did not do.
final class BodyCapabilityTests: XCTestCase {
    private func config() -> Data {
        let session: [String: Any] = [
            "instructions": "You are Someone. You can actually move.",
            "tools": [
                ["type": "function", "name": "drive_cm"],
                ["type": "function", "name": "rotate_degrees"],
                ["type": "function", "name": "stop_robot"],
                ["type": "function", "name": "read_distance"],
                ["type": "function", "name": "set_face"],
                ["type": "function", "name": "set_lights"],
                ["type": "function", "name": "get_robot_state"],
                ["type": "function", "name": "set_robot_mood"],
                ["type": "function", "name": "robot_gesture"],
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

    func testWatchingKeepsWhatTheBehaviourLoopCanAnswer() {
        let watching = OpenAIRealtimeMinter.watchingOnly(config())

        // These reach the board's own behaviour loop and work with no motion server at all.
        XCTAssertEqual(toolNames(watching), ["stop_robot", "get_robot_state", "set_robot_mood", "robot_gesture"])
    }

    func testWatchingDropsEverythingThatNeedsAMotionServer() {
        let names = toolNames(OpenAIRealtimeMinter.watchingOnly(config()))

        for steering in ["drive_cm", "rotate_degrees", "read_distance", "set_face", "set_lights"] {
            XCTAssertFalse(names.contains(steering), "\(steering) cannot be answered while watching")
        }
    }

    func testWatchingSaysPlainlyThatItCannotSteer() {
        let text = instructions(OpenAIRealtimeMinter.watchingOnly(config()))

        XCTAssertTrue(text.hasPrefix("You are Someone."), "the character survives; only the body claim changes")
        XCTAssertTrue(text.contains("YOU DO NOT DRIVE IT"))
    }

    func testNoBodyDropsEverything() {
        let none = OpenAIRealtimeMinter.withoutRobotBody(config())

        XCTAssertTrue(toolNames(none).isEmpty)
        XCTAssertTrue(instructions(none).contains("NOT CONNECTED RIGHT NOW"))
    }

    func testAnUnrecognisableConfigIsLeftAlone() {
        let odd = Data("{\"nope\":1}".utf8)

        XCTAssertEqual(OpenAIRealtimeMinter.watchingOnly(odd), odd)
    }
}
