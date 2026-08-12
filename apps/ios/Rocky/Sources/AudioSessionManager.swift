import AVFoundation

/// Configures AVAudioSession the way a real duplex voice conversation needs, not just what this
/// milestone's on-device command-word recognizer needs. Getting `.voiceChat` mode (hardware echo
/// cancellation, the thing a CyberPi could never do in software -- see apps/cyberpi/PLAN.md's
/// barge-in section) right from the start means the Realtime/barge-in milestone later doesn't
/// have to revisit the audio foundation, only what's built on top of it.
enum AudioSessionManager {
    static func configureForVoice() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)
    }
}
