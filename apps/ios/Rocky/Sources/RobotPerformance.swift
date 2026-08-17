import Foundation

/// A complete spoken performance returned in one tool call. Text and movement remain separate on
/// the wire so stage directions can never leak into Rocky's voice, while their ordering gives the
/// phone exact playback cues. Explicit pauses express dramatic timing; actual audio completion and
/// board movement onset remain measured locally rather than guessed by the model.
enum RobotPerformance {
    static let supportedMoves: Set<String> = [
        "spin", "wiggle", "forward", "fast_forward", "backward",
        "turn_left", "turn_right", "turn_around",
    ]
    enum Step: Equatable {
        case say(String)
        case move(String)
        case sound(String)
        case pause(Int)
    }

    private struct Arguments: Decodable {
        let steps: [WireStep]
    }

    private struct WireStep: Decodable {
        let kind: String
        let text: String
        let move: String
        let sound: String
        let durationMs: Int

        enum CodingKeys: String, CodingKey {
            case kind, text, move, sound
            case durationMs = "duration_ms"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(String.self, forKey: .kind)
            // Realtime function arguments occasionally omit a field even though the schema marks
            // every one required. Defaults make unused fields harmless; kind-specific validation
            // below still rejects any ambiguous or meaningful omission.
            text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
            move = try values.decodeIfPresent(String.self, forKey: .move) ?? "none"
            sound = try values.decodeIfPresent(String.self, forKey: .sound) ?? "none"
            durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        }
    }

    enum ValidationError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return reason
            }
        }
    }

    static func decode(_ json: String) throws -> [Step] {
        let arguments = try JSONDecoder().decode(Arguments.self, from: Data(json.utf8))
        guard (7...31).contains(arguments.steps.count) else {
            throw ValidationError.invalid("a performance needs 7 to 31 ordered steps")
        }

        var result: [Step] = []
        var moveCount = 0
        var soundCount = 0
        var totalPauseMs = 0
        var needsSpokenTextBeforeNextMove = false
        var spokenCharacters = 0

        for wire in arguments.steps {
            let text = wire.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch wire.kind {
            case "say":
                guard !text.isEmpty, wire.move == "none", wire.sound == "none", wire.durationMs == 0 else {
                    throw ValidationError.invalid("say steps need text and no move, sound, or duration")
                }
                spokenCharacters += text.count
                result.append(.say(text))
                needsSpokenTextBeforeNextMove = false
            case "move":
                guard text.isEmpty, wire.sound == "none", wire.durationMs == 0,
                    supportedMoves.contains(wire.move)
                else {
                    throw ValidationError.invalid("move steps need empty text and one supported movement")
                }
                guard !needsSpokenTextBeforeNextMove else {
                    throw ValidationError.invalid("put spoken story text between movement beats")
                }
                moveCount += 1
                result.append(.move(wire.move))
                needsSpokenTextBeforeNextMove = true
            case "sound":
                let sound: String?
                if wire.move == "none", StorySoundEffect(rawValue: wire.sound) != nil {
                    sound = wire.sound
                } else if wire.sound == "none", StorySoundEffect(rawValue: wire.move) != nil {
                    // Repair the unambiguous slip seen in a live dance story: the model emitted
                    // {kind:"sound", move:"chime"} and omitted sound despite the strict schema.
                    sound = wire.move
                } else {
                    sound = nil
                }
                guard text.isEmpty, wire.durationMs == 0, let sound else {
                    throw ValidationError.invalid("sound steps need one supported effect and no text, move, or duration")
                }
                soundCount += 1
                guard soundCount <= 6 else {
                    throw ValidationError.invalid("a performance can use at most 6 sound effects")
                }
                result.append(.sound(sound))
            case "pause":
                guard text.isEmpty, wire.move == "none", wire.sound == "none",
                    (100...4_000).contains(wire.durationMs)
                else {
                    throw ValidationError.invalid("pause steps need a duration from 100 to 4000 ms and no text, move, or sound")
                }
                totalPauseMs += wire.durationMs
                guard totalPauseMs <= 12_000 else {
                    throw ValidationError.invalid("a performance can pause for at most 12 seconds total")
                }
                result.append(.pause(wire.durationMs))
            default:
                throw ValidationError.invalid("performance step kind must be say, move, sound, or pause")
            }
        }

        for (index, step) in result.enumerated() {
            guard case .move = step else { continue }
            guard index + 1 < result.count, case .pause = result[index + 1] else {
                throw ValidationError.invalid("each move needs an explicit pause immediately after it")
            }
        }

        guard (2...8).contains(moveCount) else {
            throw ValidationError.invalid("a performance needs 2 to 8 movement beats")
        }
        guard spokenCharacters <= 4_000 else {
            throw ValidationError.invalid("the spoken performance is too long")
        }
        return result
    }

    /// Generation has already advanced past a cue by the time it starts playing. If playback is
    /// interrupted, replay that current cue; otherwise continue at the next untouched step.
    static func resumeIndex(nextIndex: Int, currentStepIndex: Int?) -> Int {
        currentStepIndex ?? nextIndex
    }
}
