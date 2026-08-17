import Foundation

/// A complete spoken performance returned in one tool call. Text and movement remain separate on
/// the wire so stage directions can never leak into Rocky's voice, while their ordering gives the
/// phone exact playback cues instead of making either the model or the board guess from duration.
enum RobotPerformance {
    enum Step: Equatable {
        case say(String)
        case move(String)
        case sound(String)
    }

    private struct Arguments: Decodable {
        let steps: [WireStep]
    }

    private struct WireStep: Decodable {
        let kind: String
        let text: String
        let move: String
        let sound: String
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
        guard (5...17).contains(arguments.steps.count) else {
            throw ValidationError.invalid("a performance needs 5 to 17 ordered steps")
        }

        var result: [Step] = []
        var moveCount = 0
        var soundCount = 0
        var previousWasMove = false
        var spokenCharacters = 0

        for wire in arguments.steps {
            let text = wire.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch wire.kind {
            case "say":
                guard !text.isEmpty, wire.move == "none", wire.sound == "none" else {
                    throw ValidationError.invalid("say steps need text, move=none, and sound=none")
                }
                spokenCharacters += text.count
                result.append(.say(text))
                previousWasMove = false
            case "move":
                guard text.isEmpty, wire.sound == "none",
                    wire.move == "spin" || wire.move == "wiggle"
                else {
                    throw ValidationError.invalid("move steps need empty text and a spin or wiggle")
                }
                guard !previousWasMove else {
                    throw ValidationError.invalid("put spoken story text between movement beats")
                }
                moveCount += 1
                result.append(.move(wire.move))
                previousWasMove = true
            case "sound":
                guard text.isEmpty, wire.move == "none", StorySoundEffect(rawValue: wire.sound) != nil
                else {
                    throw ValidationError.invalid("sound steps need one supported effect and no text or move")
                }
                soundCount += 1
                guard soundCount <= 6 else {
                    throw ValidationError.invalid("a performance can use at most 6 sound effects")
                }
                result.append(.sound(wire.sound))
            default:
                throw ValidationError.invalid("performance step kind must be say, move, or sound")
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
