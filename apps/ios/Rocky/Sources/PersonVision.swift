import Foundation

/// One judgment about a single camera frame: is a person in it, and roughly where.
struct PersonDetection: Equatable, Sendable {
    let personPresent: Bool
    /// Horizontal position in frame, -1 (left edge) to 1 (right edge), 0 is dead centre. Nil when
    /// no person is present or the model didn't say.
    let bearing: Double?
    /// One short phrase the model used to describe what it saw, for the debug panel only.
    let description: String?

    static let none = PersonDetection(personPresent: false, bearing: nil, description: nil)
}

/// Finds a person in a camera frame using Claude's vision, deliberately a different model and
/// provider than the OpenAI Realtime session carrying Rocky's voice.
///
/// Separate on purpose: the voice model is one continuous session that must not be paused to
/// reason about images, and mixing a second job into it would risk exactly that. A small,
/// stateless vision-only call sits alongside it instead -- one request per sampled frame, no
/// session, nothing to keep in sync with the conversation.
enum PersonVision {
    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    private static let systemPrompt = """
        You are a vision sensor for a small robot's camera. Look at the single image and report \
        whether a person is visible. Reply with exactly one line of JSON and nothing else: \
        {"person_present": true or false, "bearing": a number from -1 (person at the left edge) \
        to 1 (person at the right edge) or null, "description": a short phrase like "person, \
        facing camera" or null}. If more than one person is visible, report the one closest to \
        the camera. If no person is visible, person_present is false and bearing is null.
        """

    /// Sends one JPEG frame to Claude and returns its judgment. Throws on a missing key, a
    /// network failure, or a non-2xx response; a reply that doesn't parse falls back to `.none`
    /// rather than throwing, the same tolerance `SalienceJudge` uses for its own model replies.
    static func detectPerson(in jpegData: Data) async throws -> PersonDetection {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "RockyAnthropicKey") as? String,
            !apiKey.isEmpty
        else {
            throw RockyError.commandFailed(
                "no Anthropic API key baked into this build -- run apps/ios/scripts/generate.sh with ANTHROPIC_API_KEY set in the repo root .env, then rebuild"
            )
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 120,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": jpegData.base64EncodedString(),
                            ],
                        ],
                        ["type": "text", "text": "What do you see?"],
                    ],
                ]
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RockyError.commandFailed("no HTTP response from Anthropic")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw RockyError.commandFailed("Anthropic vision request failed (\(http.statusCode)): \(body.prefix(300))")
        }
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        let text = decoded.content.first(where: { $0.type == "text" })?.text ?? ""
        return parseDetection(text)
    }

    /// Tolerant on purpose: a reply that wraps its JSON in a sentence, or omits a field, should
    /// still be understood; one that's unrecognisable should read as "no person" rather than
    /// crash the camera loop.
    static func parseDetection(_ text: String) -> PersonDetection {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return .none }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .none }

        let present = object["person_present"] as? Bool ?? false
        guard present else { return .none }
        let bearing = (object["bearing"] as? Double).map { $0.clamped(to: -1...1) }
        let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonDetection(
            personPresent: true,
            bearing: bearing,
            description: (description?.isEmpty == false) ? description : nil
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
