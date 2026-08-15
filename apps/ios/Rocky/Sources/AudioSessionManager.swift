import AVFoundation

/// Configures AVAudioSession the way a real duplex voice conversation needs, not just what this
/// milestone's on-device command-word recognizer needs. Getting `.voiceChat` mode (hardware echo
/// cancellation, the thing a CyberPi could never do in software -- see apps/cyberpi/PLAN.md's
/// barge-in section) right from the start means the Realtime/barge-in milestone later doesn't
/// have to revisit the audio foundation, only what's built on top of it.
enum AudioSessionManager {
    private nonisolated(unsafe) static var routeObserver: NSObjectProtocol?

    static func configureForVoice() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )

        // Activation fails transiently while a previous session is still being torn down, which
        // is exactly the case when starting again right after hanging up: WebRTC is still
        // releasing the microphone. Treating that as fatal turned "pause, then start again" into
        // a failure the UI immediately retried, hundreds of times a second, until it froze. It is
        // a race, not a refusal, so wait it out.
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                try session.setActive(true)
                lastError = nil
                break
            } catch {
                lastError = error
                RockyLog.write("audio: session activation attempt \(attempt + 1) failed, retrying")
                try? await Task.sleep(for: .milliseconds(80 * (attempt + 1)))
            }
        }
        if let lastError { throw lastError }

        preferSpeakerOverReceiver(session)
        observeRouteChanges()
    }

    /// `.defaultToSpeaker` alone is not enough: `.voiceChat` mode is built for phone calls held
    /// to your ear, so it routes to the little receiver anyway. This is a robot you talk to from
    /// across the room, so push it to the loudspeaker -- but only when the receiver is what we
    /// actually landed on, so headphones, AirPods and car audio are left exactly as the user
    /// chose them.
    private static func preferSpeakerOverReceiver(_ session: AVAudioSession) {
        let onReceiver = session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
        guard onReceiver else { return }
        try? session.overrideOutputAudioPort(.speaker)
    }

    /// Losing a Bluetooth speaker mid-conversation drops the route back to the receiver, which
    /// sounds like Rocky suddenly went quiet. Re-apply the preference whenever the route moves.
    private static func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            preferSpeakerOverReceiver(AVAudioSession.sharedInstance())
        }
    }
}
