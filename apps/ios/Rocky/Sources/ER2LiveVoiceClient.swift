import Foundation

/// Feature-flagged conversational transport using Gemini Robotics ER 2 Streaming directly for
/// microphone understanding, conversational reasoning, and robot tool selection. ER2 only emits
/// text; `RealtimeVoiceSession` sends that text through the unchanged ElevenLabs pipeline.
///
/// The adapter deliberately speaks the small event language already consumed by the session.
/// This makes an ER2-vs-Realtime comparison about the model/transport instead of accidentally
/// changing the persona, robot executor, playback, UI, world projection, or logging at once.
final class ER2LiveVoiceClient: @unchecked Sendable {
    var onEvent: (@Sendable (RealtimeServerEvent) -> Void)?
    var onConnectionStateChange: (@Sendable (Bool) -> Void)?
    var onDataChannelOpen: (@Sendable () -> Void)?

    let supportsOutOfBandResponses = false
    let supportsDynamicBodyConfiguration = false
    let engineName = VoiceEngine.er2.displayName

    private static let host = "generativelanguage.googleapis.com"
    private static let model = "models/gemini-robotics-er-2-streaming-preview"
    private static let connectTimeout: Duration = .seconds(8)

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var epoch = 0
    private var open = false
    private var microphoneEnabled = true
    private var activeResponseID: String?
    private var responseText = ""
    private var nextResponseNumber = 0
    private var pendingToolCalls: [String: String] = [:]
    private var pendingToolResponses: [[String: Any]] = []
    private var continueAfterTools = false
    private var nativeAudioStarted = false

    // A tiny local energy detector exists only to preserve the session's precise barge-in and
    // latency telemetry. Gemini's own automatic VAD remains authoritative for ending turns.
    private var speechFrames = 0
    private var silenceFrames = 0
    private var locallySpeaking = false
    private var localPlaybackActive = false
    private var gatedPlaybackFrames = 0
    private var gatedPlaybackPeakRMS = 0.0

    var isDataChannelOpen: Bool { locked { open } }

    func connect(credential: String, hasBody: Bool) async throws {
        guard !credential.isEmpty else {
            throw RockyError.commandFailed(VoiceEngine.er2.missingCredentialMessage)
        }
        close()
        let currentEpoch = locked { () -> Int in
            epoch += 1
            return epoch
        }
        var components = URLComponents(
            string: "wss://\(Self.host)/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )!
        components.queryItems = [.init(name: "key", value: credential)]
        let task = URLSession.shared.webSocketTask(with: components.url!)
        locked { socket = task }
        task.resume()
        receive(on: task, epoch: currentEpoch)

        let setup = try Self.setupMessage(hasBody: hasBody)
        send(setup, on: task)
        RockyLog.write("voice: ER2 opening epoch \(currentEpoch) with \(Self.model)")

        let deadline = ContinuousClock.now + Self.connectTimeout
        while !isDataChannelOpen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard isDataChannelOpen else {
            close()
            throw RockyError.timedOut("ER2 Live setup")
        }

        RockyAudioEngine.audioDevice.startNativeRecording { [weak self] pcm in
            self?.consumeMicrophonePCM(pcm)
        }
        locked { nativeAudioStarted = true }
    }

    func send<T: Encodable>(_ event: T) {
        guard let data = try? JSONEncoder().encode(event),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        switch type {
        case "response.create":
            let instructions = ((object["response"] as? [String: Any])?["instructions"] as? String)
                ?? "Begin or continue the conversation naturally with one brief spoken response."
            beginResponseIfNeeded()
            if locked({ continueAfterTools }) {
                locked { continueAfterTools = false }
                RockyLog.write("voice: ER2 continuing automatically after tool results")
            } else {
                sendClientText(instructions, turnComplete: true)
            }

        case "conversation.item.create":
            guard let item = object["item"] as? [String: Any] else { return }
            if item["type"] as? String == "function_call_output" {
                acceptToolResponse(item)
            } else if let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { sendClientText(text, turnComplete: false) }
            }

        case "response.cancel", "output_audio_buffer.clear", "conversation.item.truncate":
            // User audio interrupts ER2 through its automatic activity detector. Playback is
            // cleared by RealtimeVoiceSession itself; Gemini has no response-id cancellation or
            // transcript-truncation analogue on this endpoint.
            break

        default:
            break
        }
    }

    @discardableResult
    func send(jsonObject: [String: Any]) -> Bool {
        guard isDataChannelOpen else { return false }
        if (jsonObject["type"] as? String) == "session.update" {
            RockyLog.write("voice: ER2 body-tool changes require the next session reconnect")
            return true
        }
        send(jsonObject)
        return true
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        let endedSpeech = locked { () -> Bool in
            microphoneEnabled = enabled
            guard !enabled, locallySpeaking else { return false }
            locallySpeaking = false
            speechFrames = 0
            silenceFrames = 0
            return true
        }
        if endedSpeech { emit(["type": "input_audio_buffer.speech_stopped"]) }
        if !enabled { send(["realtimeInput": ["audioStreamEnd": true]]) }
    }

    func setRemoteAudioEnabled(_: Bool) {}

    func setLocalPlaybackActive(_ active: Bool) {
        let summary = locked { () -> (Int, Double)? in
            guard localPlaybackActive != active else { return nil }
            localPlaybackActive = active
            speechFrames = 0
            silenceFrames = 0
            if active {
                gatedPlaybackFrames = 0
                gatedPlaybackPeakRMS = 0
                // A response cannot correctly begin while the user is still talking. Treat the
                // transition as a clean boundary so old detector state cannot leak into playback.
                locallySpeaking = false
                return nil
            }
            let result = (gatedPlaybackFrames, gatedPlaybackPeakRMS)
            gatedPlaybackFrames = 0
            gatedPlaybackPeakRMS = 0
            return result
        }
        if active {
            RockyLog.write("audio: ER2 local energy VAD gated during Rocky playback")
        } else if let summary {
            RockyLog.write(
                "audio: ER2 playback VAD gate released after \(summary.0) frames "
                    + "(peak RMS \(String(format: "%.4f", summary.1)))"
            )
        }
    }

    func close() {
        let previous: URLSessionWebSocketTask? = locked {
            epoch += 1
            let previous = socket
            socket = nil
            open = false
            activeResponseID = nil
            responseText = ""
            pendingToolCalls = [:]
            pendingToolResponses = []
            continueAfterTools = false
            locallySpeaking = false
            speechFrames = 0
            silenceFrames = 0
            localPlaybackActive = false
            gatedPlaybackFrames = 0
            gatedPlaybackPeakRMS = 0
            return previous
        }
        let stopAudio = locked { () -> Bool in
            let stop = nativeAudioStarted
            nativeAudioStarted = false
            return stop
        }
        if stopAudio { RockyAudioEngine.audioDevice.stopNativeRecording() }
        previous?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: Gemini setup

    nonisolated static func setupMessage(hasBody: Bool) throws -> [String: Any] {
        guard let baked = OpenAIRealtimeMinter.bakedSessionData() else {
            throw RockyError.commandFailed("Rocky's session config is missing from the app bundle")
        }
        let selected = hasBody ? baked : OpenAIRealtimeMinter.withoutRobotBody(baked)
        guard let root = try? JSONSerialization.jsonObject(with: selected) as? [String: Any],
            let session = root["session"] as? [String: Any],
            let instructions = session["instructions"] as? String
        else {
            throw RockyError.commandFailed("Rocky's session config is missing from the app bundle")
        }

        let tools = (session["tools"] as? [[String: Any]] ?? []).compactMap(convertTool)
        var setup: [String: Any] = [
            "model": model,
            "generationConfig": ["responseModalities": ["TEXT"]],
            "systemInstruction": [
                "parts": [[
                    "text": instructions + """


                    VOICE DELIVERY
                    - Your ordinary text is spoken aloud by your ElevenLabs voice. Write only the
                      words you intend your friend to hear: no markdown, stage directions, labels,
                      analysis, or descriptions of how you sound.
                    - Listen and respond conversationally. Visual and body context are private
                      evidence, not topics to announce unless they matter to the conversation.
                    """
                ]]
            ],
            "inputAudioTranscription": [:],
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
                    "prefixPaddingMs": 180,
                    "silenceDurationMs": 520,
                ]
            ],
        ]
        if !tools.isEmpty { setup["tools"] = [["functionDeclarations": tools]] }
        return ["setup": setup]
    }

    nonisolated static func convertTool(_ source: [String: Any]) -> [String: Any]? {
        guard let name = source["name"] as? String else { return nil }
        var result: [String: Any] = ["name": name, "behavior": "BLOCKING"]
        if let description = source["description"] { result["description"] = description }
        if let parameters = source["parameters"] as? [String: Any] {
            result["parameters"] = geminiSchema(parameters)
        }
        return result
    }

    private nonisolated static func geminiSchema(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(geminiSchema) }
        guard let object = value as? [String: Any] else { return value }
        var converted: [String: Any] = [:]
        for (key, child) in object where key != "additionalProperties" {
            if key == "type", let type = child as? String {
                converted[key] = type.uppercased()
            } else {
                converted[key] = geminiSchema(child)
            }
        }
        return converted
    }

    // MARK: Microphone and local activity telemetry

    private func consumeMicrophonePCM(_ pcm: Data) {
        guard locked({ open && microphoneEnabled }), !pcm.isEmpty else { return }
        updateLocalActivity(pcm)
        send([
            "realtimeInput": [
                "audio": [
                    "data": pcm.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ]
            ]
        ])
    }

    private func updateLocalActivity(_ pcm: Data) {
        let rms: Double = pcm.withUnsafeBytes { raw in
            let count = raw.count / 2
            guard count > 0 else { return 0 }
            var sum = 0.0
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                let sample = Double(Int16(bitPattern: low | (high << 8))) / 32_768
                sum += sample * sample
            }
            return sqrt(sum / Double(count))
        }
        if let event = localActivityEvent(rms: rms) { emit(["type": event]) }
    }

    /// Local energy is useful while Rocky is quiet, but cannot reliably distinguish a nearby
    /// friend from residual speaker energy while external TTS is playing. During playback Gemini's
    /// own interruption/transcription signal is authoritative; the microphone still streams.
    func localActivityEvent(rms: Double) -> String? {
        locked {
            if localPlaybackActive {
                gatedPlaybackFrames += 1
                gatedPlaybackPeakRMS = max(gatedPlaybackPeakRMS, rms)
                speechFrames = 0
                silenceFrames = 0
                return nil
            }
            if rms >= 0.014 {
                speechFrames += 1
                silenceFrames = 0
                if !locallySpeaking, speechFrames >= 3 {
                    locallySpeaking = true
                    return "input_audio_buffer.speech_started"
                }
            } else {
                speechFrames = 0
                if locallySpeaking {
                    silenceFrames += 1
                    if silenceFrames >= 45 {
                        locallySpeaking = false
                        silenceFrames = 0
                        return "input_audio_buffer.speech_stopped"
                    }
                }
            }
            return nil
        }
    }

    private func emitServerConfirmedSpeechStart(_ source: String) {
        let shouldEmit = locked { () -> Bool in
            guard !locallySpeaking else { return false }
            locallySpeaking = true
            speechFrames = 0
            silenceFrames = 0
            return true
        }
        guard shouldEmit else { return }
        RockyLog.write("voice: ER2 server confirmed barge-in via \(source)")
        emit(["type": "input_audio_buffer.speech_started"])
    }

    // MARK: Gemini wire protocol

    private func sendClientText(_ text: String, turnComplete: Bool) {
        send([
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": turnComplete,
            ]
        ])
    }

    private func send(_ object: [String: Any]) {
        guard let socket = locked({ open ? self.socket : nil }) else { return }
        send(object, on: socket)
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(json)) { error in
            if let error {
                RockyLog.write("voice: ER2 send failed: \(error.localizedDescription)")
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask, epoch: Int) {
        socket.receive { [weak self] result in
            guard let self, self.locked({ epoch == self.epoch && self.socket === socket }) else {
                return
            }
            switch result {
            case .failure(let error):
                let cancelled = (error as NSError).code == NSURLErrorCancelled
                let wasOpen = self.locked { () -> Bool in
                    let wasOpen = self.open
                    self.open = false
                    self.socket = nil
                    return wasOpen
                }
                if !cancelled {
                    RockyLog.write("voice: ER2 epoch \(epoch) socket failed: \(error.localizedDescription)")
                    if wasOpen { self.onConnectionStateChange?(false) }
                }
            case .success(let message):
                switch message {
                case .string(let json): self.handle(json)
                case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                if self.locked({ epoch == self.epoch && self.socket === socket }) {
                    self.receive(on: socket, epoch: epoch)
                }
            }
        }
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if object["setupComplete"] != nil {
            locked { open = true }
            RockyLog.write("voice: ER2 Live setup complete")
            onConnectionStateChange?(true)
            onDataChannelOpen?()
            return
        }
        if let content = object["serverContent"] as? [String: Any] {
            if let transcription = content["inputTranscription"] as? [String: Any],
                let text = transcription["text"] as? String, !text.isEmpty
            {
                RockyLog.write("voice: ER2 heard: \(text)")
                if locked({ localPlaybackActive }) {
                    emitServerConfirmedSpeechStart("input transcription")
                }
            }
            var delta = ""
            if let turn = content["modelTurn"] as? [String: Any],
                let parts = turn["parts"] as? [[String: Any]]
            {
                delta = parts.compactMap { $0["text"] as? String }.joined()
            } else if let transcription = content["outputTranscription"] as? [String: Any] {
                delta = transcription["text"] as? String ?? ""
            }
            if !delta.isEmpty {
                let responseID = beginResponseIfNeeded()
                locked { responseText += delta }
                emit(["type": "response.output_text.delta", "response_id": responseID, "delta": delta])
            }
            if content["interrupted"] as? Bool == true {
                emitServerConfirmedSpeechStart("Gemini interruption")
                completeResponse(status: "cancelled", reason: "turn_detected")
            } else if content["turnComplete"] as? Bool == true {
                completeResponse(status: "completed")
            }
            return
        }
        if let toolCall = object["toolCall"] as? [String: Any],
            let calls = toolCall["functionCalls"] as? [[String: Any]], !calls.isEmpty
        {
            let responseID = beginResponseIfNeeded()
            let output: [[String: Any]] = calls.compactMap { call in
                guard let id = call["id"] as? String, let name = call["name"] as? String else {
                    return nil
                }
                locked { pendingToolCalls[id] = name }
                let arguments = call["args"] as? [String: Any] ?? [:]
                let argumentData = try? JSONSerialization.data(withJSONObject: arguments)
                return [
                    "id": "er2_tool_\(id)", "type": "function_call", "name": name,
                    "call_id": id,
                    "arguments": argumentData.map { String(decoding: $0, as: UTF8.self) } ?? "{}",
                ]
            }
            let text = locked { responseText }
            if !text.isEmpty {
                emit(["type": "response.output_text.done", "response_id": responseID, "text": text])
            }
            emit([
                "type": "response.done",
                "response": ["id": responseID, "status": "completed", "output": output],
            ])
            locked {
                activeResponseID = nil
                responseText = ""
            }
            return
        }
        if let goAway = object["goAway"] as? [String: Any] {
            RockyLog.write("voice: ER2 server requested reconnect: \(goAway["timeLeft"] ?? "soon")")
            return
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"].map(String.init(describing:)) ?? "unknown"
            let message = error["message"] as? String ?? "unknown ER2 error"
            RockyLog.write("voice: ER2 server error \(code): \(message.prefix(240))")
        }
    }

    @discardableResult
    private func beginResponseIfNeeded() -> String {
        let result: (String, Bool) = locked {
            if let activeResponseID { return (activeResponseID, false) }
            nextResponseNumber += 1
            let id = "er2_r_\(nextResponseNumber)"
            activeResponseID = id
            responseText = ""
            return (id, true)
        }
        if result.1 {
            emit(["type": "response.created", "response": ["id": result.0, "status": "in_progress"]])
        }
        return result.0
    }

    private func completeResponse(status: String, reason: String? = nil) {
        guard let responseID = locked({ activeResponseID }) else { return }
        let text = locked { responseText }
        if !text.isEmpty {
            emit(["type": "response.output_text.done", "response_id": responseID, "text": text])
        }
        var response: [String: Any] = ["id": responseID, "status": status, "output": []]
        if let reason {
            response["status_details"] = ["type": status, "reason": reason]
        }
        emit(["type": "response.done", "response": response])
        locked {
            activeResponseID = nil
            responseText = ""
        }
    }

    private func acceptToolResponse(_ item: [String: Any]) {
        guard let id = item["call_id"] as? String else { return }
        let raw = item["output"] as? String ?? "{}"
        let parsed = raw.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        } ?? ["result": raw]
        let ready: [[String: Any]]? = locked {
            guard let name = pendingToolCalls.removeValue(forKey: id) else { return nil }
            pendingToolResponses.append(["id": id, "name": name, "response": parsed])
            guard pendingToolCalls.isEmpty else { return nil }
            let result = pendingToolResponses
            pendingToolResponses = []
            continueAfterTools = true
            return result
        }
        guard let ready else { return }
        send(["toolResponse": ["functionResponses": ready]])
    }

    private func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: data)
        else { return }
        onEvent?(event)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension ER2LiveVoiceClient: RealtimeVoiceClient {}
