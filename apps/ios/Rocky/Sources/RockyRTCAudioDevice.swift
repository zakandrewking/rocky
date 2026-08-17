// The structure of this RTCAudioDevice implementation follows the AVAudioEngine example linked
// from WebRTC's own RTCAudioDevice.h. Original example copyright (c) 2022 Yury Yaroshevich, MIT.

@preconcurrency import AVFoundation
@preconcurrency import WebRTC

/// One full-duplex audio device for WebRTC capture/playout and Rocky's local sound.
///
/// A second AVAudioEngine input cannot coexist reliably with WebRTC's VoIP audio unit on iPhone:
/// the 2026-08-16 device test armed that input and then starved WebRTC of every microphone frame.
/// Instead WebRTC injects this object as its audio device. Its voice-processing AVAudioEngine
/// renders all local players through the same mixer, giving AEC a truthful reference while the
/// microphone remains available to OpenAI semantic VAD throughout Rocky's speech.
final class RockyRTCAudioDevice: NSObject, @unchecked Sendable {
    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()

    private var delegateStorage: RTCAudioDeviceDelegate?
    private var shouldPlay = false
    private var shouldRecord = false
    private var interrupted = false
    private var rebuilding = false

    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var inputConverter: RockyAudioConverter?
    private var observers: [NSObjectProtocol] = []

    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    private let players: [RockyAudioEngine.Channel: AVAudioPlayerNode]

    override init() {
        var created: [RockyAudioEngine.Channel: AVAudioPlayerNode] = [:]
        for channel in RockyAudioEngine.Channel.allCases {
            created[channel] = AVAudioPlayerNode()
        }
        players = created
        super.init()

        // VoiceProcessingIO must be selected before the graph is built. WebRTC's own linked
        // example does this immediately after creating its engine; changing it after nodes are
        // connected can invalidate the hardware formats and has caused random engine failures in
        // that implementation. AudioSessionManager activates `.voiceChat` before any caller asks
        // for a player, which is when this lazy process-wide device is first initialized.
        do {
            try engine.outputNode.setVoiceProcessingEnabled(true)
            RockyLog.write("audio: shared WebRTC voice-processing graph enabled")
        } catch {
            RockyLog.write("audio: shared voice processing failed: \(error.localizedDescription)")
        }

        for player in players.values {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: RockyAudioEngine.format)
        }
    }

    // MARK: Local Rocky output

    func player(for channel: RockyAudioEngine.Channel) -> AVAudioPlayerNode {
        // All fixed players are created and attached before WebRTC sees the device, so normal
        // scheduling never mutates the graph from the main thread.
        players[channel]!
    }

    func ensureRunning() {
        guard let delegate = currentDelegate else { return }
        delegate.dispatchSync { [weak self] in
            self?.updateEngine()
        }
        for player in players.values where !player.isPlaying {
            player.play()
        }
    }

    private var currentDelegate: RTCAudioDeviceDelegate? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return delegateStorage
    }

    private func setDelegate(_ delegate: RTCAudioDeviceDelegate?) {
        stateLock.lock()
        delegateStorage = delegate
        stateLock.unlock()
    }

    // MARK: Graph

    private func updateEngine() {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }

        guard let delegate = currentDelegate, (shouldPlay || shouldRecord), !interrupted else {
            if engine.isRunning { engine.stop() }
            detachWebRTCNodes()
            return
        }

        if !engine.outputNode.isVoiceProcessingEnabled {
            engine.stop()
            do {
                try engine.outputNode.setVoiceProcessingEnabled(true)
                reconnectLocalPlayers()
                RockyLog.write("audio: shared WebRTC voice-processing graph enabled")
            } catch {
                RockyLog.write("audio: shared voice processing failed: \(error.localizedDescription)")
                return
            }
        }

        // Keep VoiceProcessingIO physically full duplex for the lifetime of an active graph.
        // Native ADM briefly asks for record-only, then play-only, then both while negotiating.
        // Mirroring those transient logical flags onto the hardware forced three stop/restart
        // cycles, occasionally left the speaker format at 0 Hz, and failed with `!pla`
        // (AVAudioSession cannot start playing). The source/sink nodes below still honor ADM's
        // logical requests; only the hardware remains stable so AEC always has both sides.
        let hardware = Self.hardwareDirections(shouldPlay: shouldPlay, shouldRecord: shouldRecord)
        let ioUnit = engine.outputNode.auAudioUnit
        if ioUnit.isInputEnabled != hardware.input || ioUnit.isOutputEnabled != hardware.output {
            if engine.isRunning { engine.stop() }
            ioUnit.isInputEnabled = hardware.input
            ioUnit.isOutputEnabled = hardware.output
        }

        if shouldRecord, sinkNode == nil {
            installInput(delegate: delegate)
        } else if !shouldRecord, let sinkNode {
            engine.detach(sinkNode)
            self.sinkNode = nil
            inputConverter = nil
        }

        if shouldPlay, sourceNode == nil {
            installOutput(delegate: delegate)
        } else if !shouldPlay, let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }

        guard !engine.isRunning else {
            startPlayers()
            return
        }
        engine.prepare()
        do {
            try engine.start()
            startPlayers()
            RockyLog.write(
                "audio: shared graph started (input: \(shouldRecord ? "on" : "off"), output: \(shouldPlay ? "on" : "off"))"
            )
        } catch {
            RockyLog.write("audio: shared graph failed to start: \(error.localizedDescription)")
        }
    }

    private func installInput(delegate: RTCAudioDeviceDelegate) {
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 1)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
            let rtcFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: hardwareFormat.sampleRate,
                channels: hardwareFormat.channelCount,
                interleaved: true
            ), let converter = RockyAudioConverter(from: hardwareFormat, to: rtcFormat)
        else {
            RockyLog.write("audio: shared graph has no valid microphone format")
            return
        }

        let deliver = delegate.deliverRecordedData
        let render: RTCAudioDeviceRenderRecordedDataBlock = {
            _, _, _, frameCount, output, context in
            guard let context else { return kAudio_ParamError }
            let pair = context.assumingMemoryBound(
                to: (Unmanaged<RockyAudioConverter>, UnsafePointer<AudioBufferList>).self
            ).pointee
            return pair.0.takeUnretainedValue().convert(
                frameCount: frameCount, from: pair.1, to: output
            )
        }
        let sink = AVAudioSinkNode { timestamp, frameCount, input in
            var flags: AudioUnitRenderActionFlags = []
            var context = (Unmanaged.passUnretained(converter), input)
            return deliver(&flags, timestamp, 1, frameCount, nil, &context, render)
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: hardwareFormat)
        sinkNode = sink
        inputConverter = converter
        inputFormat = rtcFormat
        delegate.notifyAudioInputParametersChange()
    }

    private func installOutput(delegate: RTCAudioDeviceDelegate) {
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
            let rtcFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: hardwareFormat.sampleRate,
                channels: hardwareFormat.channelCount,
                interleaved: true
            )
        else {
            RockyLog.write("audio: shared graph has no valid speaker format")
            return
        }

        let getPlayout = delegate.getPlayoutData
        let source = AVAudioSourceNode(format: rtcFormat) { silence, timestamp, frameCount, output in
            var flags: AudioUnitRenderActionFlags = []
            let status = getPlayout(&flags, timestamp, 0, frameCount, output)
            silence.pointee = ObjCBool(flags.contains(.unitRenderAction_OutputIsSilence))
            return status
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: hardwareFormat)
        sourceNode = source
        outputFormat = rtcFormat
        delegate.notifyAudioOutputParametersChange()
    }

    private func startPlayers() {
        for player in players.values where !player.isPlaying {
            player.play()
        }
    }

    /// WebRTC stream demand and hardware direction are deliberately separate. This is pure so
    /// the startup invariant can be regression-tested without touching an iPhone audio unit.
    static func hardwareDirections(
        shouldPlay: Bool, shouldRecord: Bool
    ) -> (input: Bool, output: Bool) {
        let active = shouldPlay || shouldRecord
        return (active, active)
    }

    private func detachWebRTCNodes() {
        if let sinkNode {
            engine.detach(sinkNode)
            self.sinkNode = nil
            inputConverter = nil
        }
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
    }

    private func reconnectLocalPlayers() {
        for player in players.values {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: RockyAudioEngine.format)
        }
    }

    private func rebuildAfterConfigurationChange() {
        guard let delegate = currentDelegate else { return }
        delegate.dispatchAsync { [weak self] in
            guard let self else { return }
            if self.engine.isRunning { self.engine.stop() }
            self.detachWebRTCNodes()
            self.reconnectLocalPlayers()
            delegate.notifyAudioInputInterrupted()
            delegate.notifyAudioOutputInterrupted()
            self.updateEngine()
        }
    }

    // MARK: Notifications

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                RockyLog.write("audio: shared graph configuration changed")
                self?.rebuildAfterConfigurationChange()
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: audioSession, queue: nil
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: nil
            ) { [weak self] _ in
                self?.rebuildAfterConfigurationChange()
            }
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: raw.uintValue)
        else { return }
        interrupted = type == .began
        rebuildAfterConfigurationChange()
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

// MARK: - RTCAudioDevice

extension RockyRTCAudioDevice: RTCAudioDevice {
    var deviceInputSampleRate: Double { inputFormat?.sampleRate ?? max(1, audioSession.sampleRate) }
    var inputIOBufferDuration: TimeInterval { audioSession.ioBufferDuration }
    var inputNumberOfChannels: Int { Int(inputFormat?.channelCount ?? 1) }
    var inputLatency: TimeInterval { audioSession.inputLatency }

    var deviceOutputSampleRate: Double { outputFormat?.sampleRate ?? max(1, audioSession.sampleRate) }
    var outputIOBufferDuration: TimeInterval { audioSession.ioBufferDuration }
    var outputNumberOfChannels: Int { Int(outputFormat?.channelCount ?? 1) }
    var outputLatency: TimeInterval { audioSession.outputLatency }

    var isInitialized: Bool { currentDelegate != nil }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        guard currentDelegate == nil else { return false }
        setDelegate(delegate)
        installObservers()
        return true
    }

    func terminateDevice() -> Bool {
        shouldPlay = false
        shouldRecord = false
        updateEngine()
        removeObservers()
        setDelegate(nil)
        return true
    }

    var isPlayoutInitialized: Bool { isInitialized }
    func initializePlayout() -> Bool { isInitialized }
    var isPlaying: Bool { shouldPlay }

    func startPlayout() -> Bool {
        shouldPlay = true
        updateEngine()
        return engine.isRunning
    }

    func stopPlayout() -> Bool {
        shouldPlay = false
        updateEngine()
        return true
    }

    var isRecordingInitialized: Bool { isInitialized }
    func initializeRecording() -> Bool { isInitialized }
    var isRecording: Bool { shouldRecord }

    func startRecording() -> Bool {
        shouldRecord = true
        updateEngine()
        return engine.isRunning
    }

    func stopRecording() -> Bool {
        shouldRecord = false
        updateEngine()
        return true
    }
}
