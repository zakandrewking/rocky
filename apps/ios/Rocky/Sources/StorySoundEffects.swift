import AVFoundation

enum StorySoundEffect: String, CaseIterable {
    case chime, zap, rumble, footsteps, sparkle, alarm
    case laserBlast = "laser_blast"
    case spaceshipFlyby = "spaceship_flyby"
}

/// Tiny locally rendered story effects. They deliberately use square waves, stepped pitches, and
/// deterministic noise rather than recorded samples: unmistakably 8-bit-ish, instant to start,
/// and small enough that a performance never depends on another network service.
@MainActor
final class StorySoundEffects {
    var onFinished: (() -> Void)?

    private let player = RockyAudioEngine.shared.player(for: .effects)
    private let sampleRate = RockyAudioEngine.shared.sampleRate
    private var epoch = 0
    private var completionFallback: Task<Void, Never>?

    func play(_ effect: StorySoundEffect) {
        stop()
        let currentEpoch = epoch
        guard let buffer = render(effect) else {
            onFinished?()
            return
        }
        RockyAudioEngine.shared.ensureRunning()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.finish(epoch: currentEpoch)
            }
        }
        completionFallback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(buffer.duration * 1_000) + 500))
            guard !Task.isCancelled else { return }
            self?.finish(epoch: currentEpoch)
        }
    }

    func stop() {
        epoch += 1
        completionFallback?.cancel()
        completionFallback = nil
        player.stop()
        RockyAudioEngine.shared.ensureRunning()
    }

    private func finish(epoch expectedEpoch: Int) {
        guard epoch == expectedEpoch else { return }
        epoch += 1
        completionFallback?.cancel()
        completionFallback = nil
        onFinished?()
    }

    private func render(_ effect: StorySoundEffect) -> AVAudioPCMBuffer? {
        let duration: Double = switch effect {
        case .chime: 0.55
        case .zap: 0.36
        case .rumble: 0.8
        case .footsteps: 0.72
        case .sparkle: 0.62
        case .alarm: 0.75
        case .laserBlast: 0.48
        case .spaceshipFlyby: 1.35
        }
        let frames = Int(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: RockyAudioEngine.format, frameCapacity: AVAudioFrameCount(frames)
        ), let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var noiseState: UInt32 = 0xC0FFEE
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            let progress = t / duration
            let envelope = min(1, t / 0.012) * pow(max(0, 1 - progress), 1.4)
            let value: Double
            switch effect {
            case .chime:
                let notes = [659.25, 783.99, 987.77]
                let note = notes[min(notes.count - 1, Int(progress * Double(notes.count)))]
                value = square(note, t) * 0.18
            case .zap:
                value = square(1_300 - progress * 1_050, t) * 0.2
            case .rumble:
                noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
                let noise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
                value = (square(58 + sin(t * 18) * 8, t) * 0.12) + noise * 0.035
            case .footsteps:
                let phase = progress * 4
                let pulse = phase - floor(phase) < 0.22 ? 1.0 : 0.0
                value = square(92, t) * pulse * 0.2
            case .sparkle:
                let notes = [880.0, 1_174.66, 1_318.51, 1_760.0]
                let note = notes[min(notes.count - 1, Int(progress * Double(notes.count)))]
                value = square(note, t) * 0.13
            case .alarm:
                let note = Int(t * 8).isMultiple(of: 2) ? 440.0 : 622.25
                value = square(note, t) * 0.16
            case .laserBlast:
                let carrier = 1_750 - progress * 1_420
                value = (square(carrier, t) * 0.17) + (square(carrier * 0.51, t) * 0.07)
            case .spaceshipFlyby:
                noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
                let noise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
                let doppler = 150 + (1 - progress) * 520
                let passEnvelope = sin(.pi * progress)
                value = (square(doppler, t) * 0.11 + noise * 0.035) * passEnvelope
            }
            samples[frame] = Float(value * envelope)
        }
        return buffer
    }

    private func square(_ frequency: Double, _ time: Double) -> Double {
        sin(2 * .pi * frequency * time) >= 0 ? 1 : -1
    }
}

private extension AVAudioPCMBuffer {
    var duration: Double { Double(frameLength) / format.sampleRate }
}
