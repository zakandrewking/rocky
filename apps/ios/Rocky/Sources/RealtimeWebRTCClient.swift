import Foundation
import WebRTC

/// Thin wrapper around a single WebRTC peer connection to OpenAI's Realtime API, mirroring
/// apps/desktop/src/renderer/src/App.tsx's connect flow almost line for line: create a peer
/// connection, add a local mic track, open a data channel for JSON events, create an SDP offer,
/// POST it to /v1/realtime/calls with the ephemeral secret, apply the SDP answer.
///
/// Deliberately NOT @MainActor, same reasoning as RobotTCPTransport: WebRTC's delegate callbacks
/// run on its own internal signaling/worker threads, never the main thread. A class lexically
/// written as @MainActor with delegate methods inside it would get those methods inferred as
/// MainActor-isolated by the compiler regardless of what invokes them -- exactly the crash this
/// project already hit twice with SFSpeechRecognizer/AVAudioEngine callbacks (see
/// VoiceCommandRecognizer.swift's documented incidents). Every callback here does the minimum
/// off-actor and hands typed data to @Sendable closures; RealtimeVoiceSession (the @MainActor
/// wrapper) is what hops back for UI/tool-call state.
/// `@unchecked Sendable` for the same reason as RobotTCPTransport: RealtimeVoiceSession is this
/// class's only owner and only caller, so its `connect`/`send`/`close` calls are effectively
/// single-owner even though the compiler can't see that on its own.
final class RealtimeWebRTCClient: NSObject, @unchecked Sendable {
    /// Called for every parsed data-channel JSON event. Not necessarily on the main thread.
    var onEvent: (@Sendable (RealtimeServerEvent) -> Void)?
    /// Called once the peer connection is fully connected, or once it fails/disconnects after
    /// having been connected -- not for the normal "still negotiating" intermediate states.
    var onConnectionStateChange: (@Sendable (Bool) -> Void)?
    /// Called when the event data channel reaches `.open` -- the first moment `send` will
    /// actually deliver anything, so this is what to wait on before speaking first.
    var onDataChannelOpen: (@Sendable () -> Void)?

    // WebRTC's own recommended pattern is one shared factory for the process's lifetime; this is
    // created once and only ever read after, never mutated, so nonisolated(unsafe) is an honest
    // description of the actual safety here, not just a compiler-trust escape hatch.
    private nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteAudioTracks: [RTCAudioTrack] = []

    /// Opens the connection: mints an ephemeral secret via `secretProvider`, negotiates WebRTC
    /// with OpenAI directly (no relay server -- this is exactly the pattern OpenAI's own docs
    /// describe for "mobile clients that capture or play audio directly"), and returns once the
    /// SDP answer has been applied. The data channel may still take a moment to reach `.open`
    /// after this returns; send events only once onEvent starts receiving "session.*" callbacks,
    /// or track `dataChannel.readyState` if precise gating matters.
    func connect(ephemeralSecret: String) async throws {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [] // Direct to OpenAI's own media servers; no STUN/TURN needed here.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard
            let peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: nil)
        else {
            throw RobotError.commandFailed("could not create WebRTC peer connection")
        }
        peerConnection.delegate = self
        self.peerConnection = peerConnection

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = Self.factory.audioSource(with: audioConstraints)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "rocky-mic")
        peerConnection.add(audioTrack, streamIds: ["rocky-stream"])
        localAudioTrack = audioTrack

        let dataChannelConfig = RTCDataChannelConfiguration()
        guard let channel = peerConnection.dataChannel(forLabel: "oai-events", configuration: dataChannelConfig) else {
            throw RobotError.commandFailed("could not create WebRTC data channel")
        }
        channel.delegate = self
        dataChannel = channel

        let offerConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offerSDP = try await Self.createOfferSDP(peerConnection: peerConnection, constraints: offerConstraints)
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        try await Self.setLocalDescription(peerConnection: peerConnection, description: offer)

        let answerSDP = try await Self.exchangeSDP(offerSDP: offerSDP, ephemeralSecret: ephemeralSecret)
        let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
        try await Self.setRemoteDescription(peerConnection: peerConnection, description: answer)
    }

    /// Sends one JSON event over the data channel. Silently drops the send if the channel isn't
    /// open yet -- callers that need to know should check `isDataChannelOpen` first.
    func send(_ event: some Encodable) {
        guard let dataChannel, dataChannel.readyState == .open else { return }
        guard let data = try? JSONEncoder().encode(event) else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dataChannel.sendData(buffer)
    }

    var isDataChannelOpen: Bool {
        dataChannel?.readyState == .open
    }

    /// Gates the microphone at the track, so nothing reaches OpenAI's voice-activity detection
    /// while it's off.
    ///
    /// This exists because Rocky's own voice is not echo-cancelled on this platform: Hume's audio
    /// and the Eridian chords play through AVAudioEngine, which is outside the voice-processing
    /// render path WebRTC's AEC references, so the microphone genuinely hears her. Left open, the
    /// server hears Rocky, decides the user is talking, cuts her off mid-sentence and transcribes
    /// her own words as if the user had said them.
    func setMicrophoneEnabled(_ enabled: Bool) {
        localAudioTrack?.isEnabled = enabled
    }

    /// Silences the model's own voice. Pausing has to reach this: a character voiced by the
    /// Realtime model plays through the peer connection rather than any local player, so stopping
    /// local audio leaves it talking.
    func setRemoteAudioEnabled(_ enabled: Bool) {
        for track in remoteAudioTracks {
            track.isEnabled = enabled
        }
    }

    func close() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
    }

    // MARK: - SDP exchange (plain async/await wrappers over WebRTC's completion-handler API)

    /// Returns just the SDP text, not the RTCSessionDescription wrapper -- that type isn't
    /// Sendable, and a plain String is all the caller needs (it rebuilds the .offer-typed
    /// description locally before using it).
    private static func createOfferSDP(
        peerConnection: RTCPeerConnection, constraints: RTCMediaConstraints
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            peerConnection.offer(for: constraints) { sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp.sdp)
                } else {
                    continuation.resume(throwing: error ?? RobotError.commandFailed("no SDP offer produced"))
                }
            }
        }
    }

    private static func setLocalDescription(
        peerConnection: RTCPeerConnection, description: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func setRemoteDescription(
        peerConnection: RTCPeerConnection, description: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// POST .../v1/realtime/calls with the SDP offer and the ephemeral secret, same endpoint and
    /// auth shape as apps/desktop's own connect flow -- direct to OpenAI, no relay server.
    private static func exchangeSDP(offerSDP: String, ephemeralSecret: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ephemeralSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offerSDP.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            throw RobotError.commandFailed("voice connection failed (\(status)): \(body.prefix(300))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension RealtimeWebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // The model's own voice arrives here. Held onto so it can actually be silenced -- for a
        // character voiced by the Realtime model there is no local player to stop, so without a
        // handle on this track "pause" could not stop the talking.
        remoteAudioTracks = stream.audioTracks
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .connected, .completed:
            onConnectionStateChange?(true)
        case .failed, .disconnected, .closed:
            onConnectionStateChange?(false)
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension RealtimeWebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            onDataChannelOpen?()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        guard let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: buffer.data) else { return }
        onEvent?(event)
    }
}
