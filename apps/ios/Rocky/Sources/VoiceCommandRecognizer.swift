import AVFoundation
import Speech

/// Deliberately minimal for the first installable milestone: a fixed vocabulary matched against
/// on-device speech recognition, not a full Realtime/LLM pipeline (see apps/robot/PLAN.md and
/// this project's own README for why -- fewest moving parts to prove "phone hears me, robot
/// moves, stays safe" before adding personality/tool-calling on top).
enum RobotVoiceCommand: Sendable {
    case forward, backward, left, right, stop
}

/// Thread-safe holder for "the request the live audio tap should append to right now." Needed
/// because the tap is installed once and stays running continuously (see the class doc below for
/// why), but which SFSpeechAudioBufferRecognitionRequest is "current" changes every utterance
/// cycle -- and the tap's callback runs on a real-time audio thread that can't touch @MainActor
/// state (see installTap's doc). `@unchecked Sendable` + a lock, not `nonisolated(unsafe)`: unlike
/// the connect-timeout `settled` flags elsewhere in this app (genuinely single-writer, serial by
/// construction), this really is written from MainActor and read from the audio thread
/// concurrently, so it needs real synchronization, not just a compiler-trust annotation.
private final class CurrentRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }
}

@MainActor
final class VoiceCommandRecognizer: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastRecognizedText = ""
    @Published private(set) var lastError: String?

    var onCommand: ((RobotVoiceCommand) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let requestBox = CurrentRequestBox()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engineRunning = false
    /// Reset at the start of each recognition cycle -- lets partial results match immediately
    /// (waiting for `isFinal` turned out to starve real commands, see startRecognitionCycle's doc)
    /// while still firing at most once per utterance instead of once per partial update.
    private var matchedThisCycle = false

    /// Must be called once, before start(), with the user's explicit consent already implied by
    /// them tapping a "listen" control -- Speech/mic permission prompts happen inside this call.
    func requestAuthorization() async -> Bool {
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// A crash, confirmed via a pulled device crash report: SFSpeechRecognizer.requestAuthorization's
    /// completion closure, when written directly inside a method of this @MainActor class, gets
    /// inferred as MainActor-isolated by the compiler -- but iOS actually invokes it from its own
    /// internal TCC/permissions queue, never the main thread. The runtime's actor-isolation check
    /// traps (EXC_BREAKPOINT/SIGTRAP) the moment the OS calls back. `nonisolated static` keeps this
    /// closure out of the @MainActor inference entirely, regardless of whether the SDK's completion
    /// handler type happens to be marked @Sendable.
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Sets up the mic input once and leaves it running for the whole listening session --
    /// confirmed via a pulled session.log that the earlier design (tearing down and rebuilding the
    /// whole AVAudioEngine + tap on every single utterance boundary, in both start() and stop())
    /// was the real cause of a fast "No speech detected" error cascade: real speech showed up in
    /// partial transcripts, then the task errored out before ever reaching a final result, over
    /// and over, a few seconds apart. Tearing down and rebuilding the entire audio pipeline that
    /// often is exactly the kind of churn that starves a recognizer of a stable audio stream.
    /// Now only the lightweight SFSpeechAudioBufferRecognitionRequest + SFSpeechRecognitionTask
    /// pair gets replaced per utterance (startRecognitionCycle); the engine and tap stay alive.
    func start() {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            lastError = "speech recognizer unavailable"
            return
        }

        isListening = true
        lastError = nil

        if !engineRunning {
            do {
                try AudioSessionManager.configureForVoice()
            } catch {
                lastError = "audio session: \(error.localizedDescription)"
                isListening = false
                return
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                lastError = "invalid input format (sampleRate=\(format.sampleRate))"
                isListening = false
                return
            }
            Self.installTap(on: inputNode, format: format, box: requestBox)

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                lastError = "audio engine: \(error.localizedDescription)"
                inputNode.removeTap(onBus: 0)
                isListening = false
                return
            }
            engineRunning = true
        }

        startRecognitionCycle()
    }

    /// A second confirmed crash, same class as requestSpeechAuthorization() above but a sharper
    /// lesson: this closure captures ONLY the request box (a plain, non-actor object), never
    /// `self` -- and the earlier per-request version of this still crashed. What matters is not
    /// what a closure captures but *where it's written*: a closure literal inside a @MainActor
    /// method's body defaults to MainActor-isolated purely from lexical context, because
    /// AVAudioNodeTapBlock isn't marked @Sendable in the SDK. iOS invokes the tap from a real-time
    /// audio thread, never main, so the isolation check traps. `nonisolated static` is the fix,
    /// same as everywhere else in this file. Installed once now (see start()'s doc), so this only
    /// runs once per listening session rather than once per utterance.
    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        box: CurrentRequestBox
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
    }

    /// Starts one utterance's worth of recognition -- a fresh request/task pair fed by the same
    /// continuously-running audio tap (see start()'s doc for why the engine itself isn't touched
    /// here).
    private func startRecognitionCycle() {
        guard isListening, let speechRecognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16, *) {
            request.addsPunctuation = false
        }
        requestBox.set(request)
        matchedThisCycle = false

        recognitionTask = Self.startRecognitionTask(recognizer: speechRecognizer, request: request) { [weak self] text, isFinal, error in
            Task { @MainActor in
                self?.handleRecognitionUpdate(text: text, isFinal: isFinal, error: error)
            }
        }
    }

    /// Same reasoning as requestSpeechAuthorization() above -- recognitionTask's result handler has
    /// the identical shape (a completion closure written inside a @MainActor method, invoked by the
    /// Speech framework from its own internal queue), so it carries the same crash risk even though
    /// this specific one hadn't crashed yet. `nonisolated static` here, hopping to @MainActor
    /// explicitly in the caller above, rather than waiting for a second crash report to prove it.
    /// Extracts plain values (String/Bool) rather than passing SFSpeechRecognitionResult itself
    /// across the @Sendable/@MainActor boundary -- it's an Apple type this project doesn't control
    /// and isn't Sendable, so the compiler rejects sending it across directly.
    nonisolated private static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        completion: @escaping @Sendable (String?, Bool, Error?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            completion(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }

    private func handleRecognitionUpdate(text: String?, isFinal: Bool, error: Error?) {
        if let text {
            lastRecognizedText = text
            RockyLog.write("heard (\(isFinal ? "final" : "partial")): \(text)")
            // Matching only on isFinal starved real commands -- confirmed via session.log,
            // utterances kept erroring out ("No speech detected") before ever reaching a final
            // result, even when the correct word had already shown up in a partial transcript.
            // Match on partials too, but at most once per cycle (matchedThisCycle, reset in
            // startRecognitionCycle), so "forward" said once doesn't fire on every partial that
            // still contains it as the transcript grows.
            if !matchedThisCycle {
                matchCommand(in: text)
            }
        }
        if let error {
            lastError = error.localizedDescription
            RockyLog.write("recognition error: \(error.localizedDescription)")
        }
        if error != nil || isFinal {
            startRecognitionCycle()
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.set(nil)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        engineRunning = false
    }

    /// Tiny fixed-vocabulary match, not NLU -- "go forward please" and "forward" both work,
    /// "afterward" does not (checked as a whole-word match, not substring, to avoid that).
    private func matchCommand(in text: String) {
        let words = Set(text.lowercased().split(separator: " ").map(String.init))
        let command: RobotVoiceCommand?
        if words.contains("stop") {
            command = .stop
        } else if words.contains("forward") {
            command = .forward
        } else if words.contains("back") || words.contains("backward") {
            command = .backward
        } else if words.contains("left") {
            command = .left
        } else if words.contains("right") {
            command = .right
        } else {
            command = nil
        }
        guard let command else {
            RockyLog.write("matched: (none)")
            return
        }
        matchedThisCycle = true
        RockyLog.write("matched: \(command)")
        onCommand?(command)
    }
}
