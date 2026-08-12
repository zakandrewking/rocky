import AVFoundation
import Speech

/// Deliberately minimal for the first installable milestone: a fixed vocabulary matched against
/// on-device speech recognition, not a full Realtime/LLM pipeline (see apps/robot/PLAN.md and
/// this project's own README for why -- fewest moving parts to prove "phone hears me, robot
/// moves, stays safe" before adding personality/tool-calling on top).
enum RobotVoiceCommand: Sendable {
    case forward, backward, left, right, stop
}

@MainActor
final class VoiceCommandRecognizer: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastRecognizedText = ""
    @Published private(set) var lastError: String?

    var onCommand: ((RobotVoiceCommand) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Must be called once, before start(), with the user's explicit consent already implied by
    /// them tapping a "listen" control -- Speech/mic permission prompts happen inside this call.
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            lastError = "speech recognizer unavailable"
            return
        }

        do {
            try AudioSessionManager.configureForVoice()
        } catch {
            lastError = "audio session: \(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16, *) {
            request.addsPunctuation = false
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            lastError = "audio engine: \(error.localizedDescription)"
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            return
        }

        isListening = true
        lastError = nil

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.lastRecognizedText = text
                    self.matchCommand(in: text)
                }
                if let error {
                    self.lastError = error.localizedDescription
                }
                // SFSpeechRecognitionTask ends on silence/timeout even with shouldReportPartialResults;
                // restart immediately so "listening" is effectively continuous, not one-shot.
                if error != nil || result?.isFinal == true {
                    self.stop()
                    self.start()
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    /// Tiny fixed-vocabulary match, not NLU -- "go forward please" and "forward" both work,
    /// "afterward" does not (checked as a whole-word match, not substring, to avoid that).
    private func matchCommand(in text: String) {
        let words = Set(text.lowercased().split(separator: " ").map(String.init))
        if words.contains("stop") {
            onCommand?(.stop)
        } else if words.contains("forward") {
            onCommand?(.forward)
        } else if words.contains("back") || words.contains("backward") {
            onCommand?(.backward)
        } else if words.contains("left") {
            onCommand?(.left)
        } else if words.contains("right") {
            onCommand?(.right)
        }
    }
}
