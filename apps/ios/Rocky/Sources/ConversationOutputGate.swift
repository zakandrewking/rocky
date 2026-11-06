import Foundation

/// Network cancellation is asynchronous. Paused/backgrounded conversations must not play late
/// output or execute tools, and a cancelled response must stay suppressed after resume.
struct ConversationOutputGate {
    enum Decision: Equatable { case process, ignore, cancel(String) }
    private var suppressed: [String] = []

    mutating func suppress(_ id: String?) {
        guard let id, !suppressed.contains(id) else { return }
        suppressed.append(id)
        if suppressed.count > 64 { suppressed.removeFirst() }
    }

    mutating func decision(type: String, responseID: String?, blocked: Bool) -> Decision {
        if let responseID, suppressed.contains(responseID) { return .ignore }
        guard blocked else { return .process }
        if type == "response.created", let responseID {
            suppress(responseID)
            return .cancel(responseID)
        }
        if type.hasPrefix("response.") || type.hasPrefix("output_audio_buffer.")
            || type.hasPrefix("input_audio_buffer.speech_") {
            suppress(responseID)
            return .ignore
        }
        return .process
    }
}
