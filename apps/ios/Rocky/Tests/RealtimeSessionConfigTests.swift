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

    /// Rocky's eyes are the phone's front camera, and it runs on the voice conversation, not on
    /// whether discovery found a robot. Stripping `look_now` with the movement tools would blind a
    /// voice-only Rocky whose camera is in fact wide open and describing the room to her.
    func testKeepsThePhonesOwnToolsWhenThereIsNoRobot() {
        let input = config(
            tools: [
                ["type": "function", "name": "robot_gesture"],
                ["type": "function", "name": "look_now"],
            ],
            instructions: "You are Rocky."
        )

        let stripped = session(of: OpenAIRealtimeMinter.withoutRobotBody(input))
        let names = (stripped["tools"] as! [[String: Any]]).map { $0["name"] as! String }

        XCTAssertEqual(names, ["look_now"])
        XCTAssertEqual(stripped["tool_choice"] as! String, "auto")
        XCTAssertTrue((stripped["instructions"] as! String).contains("You can still see normally"))
    }

    func testCorrectsTheBodyContextSoRockyDoesNotPromiseABodySheHasNot() {
        let input = config(tools: [], instructions: "You are Rocky. It moves itself.")

        let instructions = session(of: OpenAIRealtimeMinter.withoutRobotBody(input))["instructions"] as! String

        // Kept, not replaced: the persona itself still comes from session.ts. Only the body
        // claim is overridden, and it has to land last to win.
        XCTAssertTrue(instructions.hasPrefix("You are Rocky. It moves itself."))
        XCTAssertTrue(instructions.contains("WHAT YOU CAN FEEL RIGHT NOW"))
        XCTAssertTrue(instructions.contains("Never say your body is unavailable"))
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
        XCTAssertEqual((connectedSession["tools"] as? [Any])?.count, 9)
        XCTAssertEqual(connectedSession["tool_choice"] as? String, "auto")
        // Not zero: losing the body does not close Rocky's eyes.
        XCTAssertEqual(
            (voiceOnlySession["tools"] as? [[String: Any]])?.map { $0["name"] as? String }, ["look_now"]
        )
        XCTAssertEqual(voiceOnlySession["tool_choice"] as? String, "auto")
        XCTAssertTrue(
            (voiceOnlySession["instructions"] as? String)?.contains("WHAT YOU CAN FEEL RIGHT NOW") == true
        )
    }

    func testTheBakedCatalogKeepsRockyAsItsOnlyFixedPersonality() throws {
        let data = try XCTUnwrap(OpenAIRealtimeMinter.bakedSessionData())
        let instructions = session(of: data)["instructions"] as? String

        XCTAssertTrue(instructions?.contains("You are Rocky") == true)
    }

    func testER2SetupReusesThePersonaAndConvertsToolsToBlockingGeminiDeclarations() throws {
        let message = try ER2LiveVoiceClient.setupMessage(hasBody: true)
        let setup = try XCTUnwrap(message["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-robotics-er-2-streaming-preview")
        XCTAssertNotNil(setup["inputAudioTranscription"])
        XCTAssertNil(setup["realtimeInputConfig"])

        let instruction = try XCTUnwrap(setup["systemInstruction"] as? [String: Any])
        let parts = try XCTUnwrap(instruction["parts"] as? [[String: Any]])
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("You are Rocky") == true)
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("ElevenLabs voice") == true)

        let groups = try XCTUnwrap(setup["tools"] as? [[String: Any]])
        let tools = try XCTUnwrap(groups.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 8)
        XCTAssertTrue(tools.allSatisfy { $0["behavior"] as? String == "BLOCKING" })
        XCTAssertFalse(tools.contains { ($0["name"] as? String) == "look_now" })
        let firstSchema = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
        XCTAssertEqual(firstSchema["type"] as? String, "OBJECT")
        XCTAssertNil(firstSchema["additionalProperties"])
    }

    func testER2VoiceOnlySetupKeepsEyesButDropsBodyTools() throws {
        let message = try ER2LiveVoiceClient.setupMessage(hasBody: false)
        let setup = try XCTUnwrap(message["setup"] as? [String: Any])
        XCTAssertNil(setup["tools"])
    }

    func testER2LocalActivityIsGatedOnlyForPlaybackDiagnostics() {
        let client = ER2LiveVoiceClient()
        client.setLocalPlaybackActive(true)
        for _ in 0..<4 { XCTAssertNil(client.localActivityEvent(rms: 0.25)) }

        client.setLocalPlaybackActive(false)
        XCTAssertNil(client.localActivityEvent(rms: 0.25))
        XCTAssertNil(client.localActivityEvent(rms: 0.25))
        XCTAssertEqual(
            client.localActivityEvent(rms: 0.25),
            "input_audio_buffer.speech_started"
        )
        for _ in 0..<44 { XCTAssertNil(client.localActivityEvent(rms: 0)) }
        XCTAssertEqual(
            client.localActivityEvent(rms: 0),
            "input_audio_buffer.speech_stopped"
        )
    }

    func testER2MicrophoneUsesTheDedicatedLiveAudioEnvelope() throws {
        let message = ER2LiveVoiceClient.audioMessage(Data([0x00, 0x80, 0xFF, 0x7F]))
        let realtime = try XCTUnwrap(message["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtime["audio"] as? [String: Any])

        XCTAssertNil(realtime["mediaChunks"])
        XCTAssertEqual(audio["data"] as? String, "AID/fw==")
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
    }
}
