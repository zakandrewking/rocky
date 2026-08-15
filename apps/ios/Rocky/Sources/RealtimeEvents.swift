import Foundation

/// Minimal typed slice of the Realtime API's data-channel event schema -- only what this app
/// actually reads, mirroring apps/desktop/src/renderer/src/App.tsx's handleRealtimeEvent, not
/// the full event union. Swift's Codable ignores unmodeled keys by default, so a `response.done`
/// event with many more fields than `output` still decodes fine here.
struct RealtimeServerEvent: Decodable, Sendable {
    let type: String
    let response: ResponseObject?
    let error: ErrorObject?
    /// Streaming text for `response.output_text.delta` and transcript deltas -- what feeds Hume
    /// and the Eridian chord layer when Rocky speaks in her own voice.
    let delta: String?
    /// The whole utterance on `response.output_text.done`.
    let text: String?

    struct ResponseObject: Decodable, Sendable {
        let output: [OutputItem]?
    }

    /// `type` is "function_call" for tool calls; other output item types (e.g. "message") also
    /// flow through here but are ignored since only tool calls need explicit handling -- audio
    /// output arrives over the WebRTC media track, not this data channel.
    struct OutputItem: Decodable, Sendable {
        let type: String
        let name: String?
        let arguments: String?
        let call_id: String?
    }

    struct ErrorObject: Decodable, Sendable {
        let message: String?
    }

    /// Every `function_call` item in a `response.done` event's output, empty otherwise.
    var toolCalls: [OutputItem] {
        guard type == "response.done" else { return [] }
        return (response?.output ?? []).filter { $0.type == "function_call" }
    }
}

/// Matches apps/desktop/src/shared/realtimeEvents.ts's RESPONSE_CREATE_EVENT -- deliberately no
/// response-level instructions; session instructions own the persona.
struct ResponseCreateEvent: Encodable, Sendable {
    let type = "response.create"
}

struct ResponseCancelEvent: Encodable, Sendable {
    let type = "response.cancel"
}

/// Sent after executing a tool call, matching App.tsx's handleSpreadsheetTool and friends
/// exactly: a conversation.item.create carrying a function_call_output, followed separately by
/// a ResponseCreateEvent to prompt the model to continue.
struct FunctionCallOutputEvent: Encodable, Sendable {
    let type = "conversation.item.create"
    let item: Item

    struct Item: Encodable, Sendable {
        let type = "function_call_output"
        let call_id: String
        let output: String
    }

    init(callId: String, output: String) {
        item = Item(call_id: callId, output: output)
    }
}
