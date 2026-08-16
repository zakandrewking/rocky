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
    /// The item a `response.output_item.added` refers to. Held onto because truncating an
    /// interrupted utterance needs the assistant item's id, and this is the only event that
    /// carries it.
    let item: OutputItem?
    /// Present on `conversation.item.*` events.
    let item_id: String?
    /// Present on every streaming event belonging to a response. The only way to tell an
    /// out-of-band salience judgment's deltas from Rocky's actual speech, since both arrive on
    /// the same data channel.
    let response_id: String?

    struct ResponseObject: Decodable, Sendable {
        let id: String?
        let output: [OutputItem]?
        /// "completed", "cancelled", "failed", "incomplete" -- anything but the first is a turn
        /// that will never produce audio, and needs to be released rather than waited on.
        let status: String?
        let status_details: StatusDetails?
        /// Echoed back verbatim from `response.create`. The correlation channel for out-of-band
        /// salience judgments, which is why they can run several deep without being confusable.
        let metadata: [String: String]?
        /// What this response actually cost. Read for one specific reason: prompt caching is
        /// exact-prefix, and this world model *edits* conversation history, so how much of the
        /// prefix survived is a direct measurement of what that editing costs. Guessing at it
        /// would be exactly the kind of unmeasured constant this project keeps regretting.
        let usage: Usage?

        struct Usage: Decodable, Sendable {
            let input_tokens: Int?
            let output_tokens: Int?
            let input_token_details: InputTokenDetails?

            struct InputTokenDetails: Decodable, Sendable {
                let cached_tokens: Int?
                let text_tokens: Int?
                let audio_tokens: Int?
            }

            /// The share of input tokens that came from the cache, 0-100. The number to watch: a
            /// long conversation should sit high, and a drop right after a state projection means
            /// a deletion rewrote history behind something.
            var cachedPercent: Int {
                guard let total = input_tokens, total > 0 else { return 0 }
                return Int((Double(input_token_details?.cached_tokens ?? 0) / Double(total) * 100).rounded())
            }
        }

        struct StatusDetails: Decodable, Sendable {
            let type: String?
            let reason: String?
            let error: ErrorObject?
        }
    }

    /// `type` is "function_call" for tool calls; other output item types (e.g. "message") also
    /// flow through here but are ignored since only tool calls need explicit handling -- audio
    /// output arrives over the WebRTC media track, not this data channel.
    struct OutputItem: Decodable, Sendable {
        let id: String?
        let type: String
        let name: String?
        let arguments: String?
        let call_id: String?
        let content: [Content]?

        struct Content: Decodable, Sendable {
            let type: String?
            let text: String?
            let transcript: String?
        }

        /// Whatever text this item carries, whichever field it arrived in.
        var spokenText: String {
            (content ?? []).compactMap { $0.text ?? $0.transcript }.joined()
        }
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

/// Matches apps/desktop/src/shared/realtimeEvents.ts's RESPONSE_CREATE_EVENT: normally no
/// response-level instructions, because the session instructions own the persona.
///
/// The one exception is a nudge that applies to a single reply and would be wrong as a standing
/// rule -- coming back from a pause, where Rocky needs to know she was away without that becoming
/// part of who she is for the rest of the conversation; or reacting to something that just
/// happened to her body.
struct ResponseCreateEvent: Encodable, Sendable {
    let type = "response.create"
    let response: ResponseConfig?

    struct ResponseConfig: Encodable, Sendable {
        let instructions: String
    }

    init(instructions: String? = nil) {
        response = instructions.map(ResponseConfig.init)
    }
}

/// A response that runs *beside* the conversation instead of inside it.
///
/// `conversation: "none"` is what makes this possible, and it is doing two jobs at once. It keeps
/// the judgment out of Rocky's history -- she never hears herself deliberating -- and it is the
/// only way to have a second response in flight at all: the Realtime API permits exactly one
/// in-band response, and a second `response.create` on the default conversation is rejected with
/// "Conversation already has an active response". Since the entire point here is to think about
/// an utterance *while it is still being spoken*, in-band was never an option.
///
/// Text-only, no tools, and everything it needs to see is inlined rather than referenced by item
/// id -- so a judgment cannot be invalidated by the very item it was reasoning about being
/// cancelled underneath it.
struct OutOfBandResponseEvent: Encodable, Sendable {
    let type = "response.create"
    let response: Config

    struct Config: Encodable, Sendable {
        let conversation = "none"
        let output_modalities = ["text"]
        let tools: [String] = []
        let metadata: [String: String]
        let instructions: String
        let input: [InputItem]
    }

    struct InputItem: Encodable, Sendable {
        let type = "message"
        let role = "user"
        let content: [Content]

        struct Content: Encodable, Sendable {
            let type = "input_text"
            let text: String
        }

        init(text: String) {
            content = [Content(text: text)]
        }
    }

    init(metadata: [String: String], instructions: String, input: String) {
        response = Config(metadata: metadata, instructions: instructions, input: [InputItem(text: input)])
    }
}

/// Cancels a response. The id is optional in the API -- omitting it cancels whatever is currently
/// active on the default conversation -- but naming it is the race-safe form, and this system
/// cancels precisely because something else has already changed underneath.
struct ResponseCancelEvent: Encodable, Sendable {
    let type = "response.cancel"
    let response_id: String?

    init(responseId: String? = nil) {
        response_id = responseId
    }
}

/// WebRTC-only: drops audio that has already been sent for playback. `response.cancel` stops the
/// model generating; it cannot un-send what is already in the buffer, so without this Rocky keeps
/// talking for a second or two after being interrupted.
struct OutputAudioBufferClearEvent: Encodable, Sendable {
    let type = "output_audio_buffer.clear"
}

/// Drops the server-side transcript of audio the person never actually heard, so the model's
/// memory of what it said matches what was said. Without it, an interrupted Rocky remembers
/// finishing a sentence nobody heard the end of, and refers back to it.
struct ConversationItemTruncateEvent: Encodable, Sendable {
    let type = "conversation.item.truncate"
    let item_id: String
    let content_index: Int
    let audio_end_ms: Int

    init(itemId: String, audioEndMs: Int) {
        item_id = itemId
        content_index = 0
        audio_end_ms = max(0, audioEndMs)
    }
}

/// Puts something in front of the model without asking it to say anything. Creating an item never
/// triggers a response on its own, which is exactly what "she should know this, she should not
/// necessarily talk about it" needs.
///
/// The `id` is client-assigned. The API allows this ("may be provided by the client or generated
/// by the server") and the whole supersession scheme depends on it: a state snapshot can only be
/// deleted when it is replaced if we knew its id before we sent it.
struct ConversationItemCreateEvent: Encodable, Sendable {
    let type = "conversation.item.create"
    let item: Item

    struct Item: Encodable, Sendable {
        let id: String
        let type = "message"
        let role = "user"
        let content: [Content]

        struct Content: Encodable, Sendable {
            let type = "input_text"
            let text: String
        }
    }

    init(id: String, text: String) {
        item = Item(id: id, content: [Item.Content(text: text)])
    }
}

/// Removes an item from the conversation. What makes superseded robot state *gone* rather than
/// merely older: there is then no stale snapshot in history for a response to read.
struct ConversationItemDeleteEvent: Encodable, Sendable {
    let type = "conversation.item.delete"
    let item_id: String

    init(id: String) {
        item_id = id
    }
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
