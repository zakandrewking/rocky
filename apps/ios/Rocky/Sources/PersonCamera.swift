import AVFoundation
import CoreImage
import Foundation
import os

/// Owns the front camera and turns it into a steady trickle of person-detection judgments.
///
/// The front camera, not the rear one: the phone's screen shows Rocky's face outward
/// (`OrbView` in `ContentView`), so the camera on the same side is the one pointed at whoever
/// Rocky is looking at.
///
/// Runs for exactly the lifetime of a voice conversation -- `ContentView` calls `start()` the
/// moment a conversation connects and `stop()` the moment it pauses, ends, or fails (see its
/// `voiceSession.state` observer). That is the whole privacy story: the camera is never on when
/// the app is merely open, only while you are actively talking to Rocky, and it stops the instant
/// that stops being true. This never records or persists a frame either way -- each frame lives
/// only long enough to be downscaled, sent to `PersonVision`, and discarded, with no video file
/// and no photo-library write.
///
/// Captures a continuous video stream rather than discrete photos, throttled in software to one
/// sample roughly every second -- a still-photo capture per tick has real shutter latency; a
/// throttled frame from an already-running video feed does not, which is what makes tracking feel
/// like tracking rather than a slideshow.
@MainActor
final class PersonCamera: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    /// The newest judged frame, carrying its own timestamps so anything downstream can ask how
    /// old this look actually is rather than assuming "latest" means "now".
    @Published private(set) var lastSample: VisionSample?
    @Published private(set) var lastError: String?
    /// True while a sampled frame is out being judged, so the throttle can skip rather than pile
    /// a second request on top of a slow one.
    @Published private(set) var isDetecting = false

    var lastReading: SceneReading? { lastSample?.reading }

    /// How often to sample a frame. Gemini's documented input shape for this model is JPEG frames
    /// at ≤1fps; this stays just inside that rather than at its edge. Read from the nonisolated
    /// capture-delivery queue below, so it has to be nonisolated itself rather than main-actor
    /// like the rest of this class.
    private nonisolated static let sampleInterval: TimeInterval = 1.0
    /// Reused across frames -- CIContext is expensive to create and safe to share, per Apple's
    /// docs, across concurrent renders. Also read from the nonisolated delivery queue.
    private nonisolated static let ciContext = CIContext()

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "family.rocky.personcamera.video")
    private let vision = PersonVision(label: "passive")
    /// Explicit questions never wait behind the passive frame already being judged. This second
    /// Live session is warmed with the camera and consumes only a frame requested by `look_now`.
    private let lookVision = PersonVision(label: "look")
    private var configured = false

    /// Frames arrive on `videoQueue`, serially but off the main actor; detection state
    /// (`isDetecting`, `lastDetection`, ...) is main-actor-isolated. This lock is the one thing
    /// both sides may touch, so the throttle -- "are we already mid-request, and is it too soon
    /// since the last one" -- can be decided cheaply on the delivery queue before ever paying for
    /// a CVPixelBuffer → JPEG conversion on a frame that's going to be dropped anyway.
    private struct ThrottleState {
        var lastSampleAt = Date.distantPast
        var inFlight = false
        var lookAfter: Date?
        var lookGeneration = 0
        var lookInFlight = false
        /// Allocated when light hits the camera, not when a model happens to answer. Passive and
        /// explicit lanes can finish out of order; sequence must still mean visual time order.
        var sampleSeq = 0
    }
    private let throttle = OSAllocatedUnfairLock(initialState: ThrottleState())

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Requests camera access if needed, configures the front camera once, and starts the video
    /// feed. Safe to call again while already running.
    func start() async {
        guard !isRunning else { return }
        lastError = nil

        let authorized: Bool
        switch authorizationStatus {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard authorized else {
            lastError = "camera access not granted -- enable it in Settings"
            RockyLog.write("camera: \(lastError!)")
            return
        }

        if !configured {
            guard configure() else {
                lastError = "no front camera available on this device"
                RockyLog.write("camera: \(lastError!)")
                return
            }
            configured = true
        }

        // A stale `lastSampleAt`/`inFlight` from a previous run would otherwise either delay the
        // first frame of this one by a full interval or block it outright.
        throttle.withLock { state in
            let sampleSeq = state.sampleSeq
            state = ThrottleState()
            // A paused Realtime conversation keeps its history. Do not restart at one on resume,
            // or the prompt's highest-sequence-wins rule would prefer a pre-pause glimpse.
            state.sampleSeq = sampleSeq
        }
        session.startRunning()
        isRunning = true
        RockyLog.write("camera: started")
        // Do not hold camera startup on a second provider handshake. Warming in parallel makes a
        // later explicit look demand-driven without adding setup latency to the voice connection.
        Task { @MainActor [weak self] in
            do {
                try await self?.lookVision.prepare()
                RockyLog.write("camera: explicit-look lane ready")
            } catch {
                RockyLog.write("camera: explicit-look warmup failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        session.stopRunning()
        vision.disconnect()
        lookVision.disconnect()
        isRunning = false
        isDetecting = false
        RockyLog.write("camera: stopped")
    }

    /// Arms the next camera frame captured after the tool call for a separate, high-priority
    /// judgment. Publishing that result through `lastSample` keeps a single downstream path into
    /// `RealtimeVoiceSession`, whose existing freshness waiter resolves it.
    func requestFreshLook(capturedAfter moment: Date) {
        guard isRunning else {
            RockyLog.write("camera: explicit look rejected because capture is not running")
            return
        }
        let generation = throttle.withLock { state -> Int in
            state.lookGeneration += 1
            state.lookAfter = moment
            return state.lookGeneration
        }
        RockyLog.write(
            "camera: explicit look g\(generation) requested after \(Self.timestamp(moment))"
        )
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input),
            session.canAddOutput(videoOutput)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // The throttle already drops all but ~1fps; a queued backlog of frames we'll never look
        // at just holds memory and adds latency to the ones we do want.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)
        session.commitConfiguration()
        return true
    }

    private func handleFrame(jpegData: Data, capturedAt: Date, seq: Int) async {
        defer { throttle.withLock { $0.inFlight = false } }
        guard isRunning else { return }
        isDetecting = true
        defer { isDetecting = false }
        do {
            let reading = try await vision.read(frame: jpegData)
            let sample = VisionSample(
                seq: seq, capturedAt: capturedAt, judgedAt: Date(), reading: reading
            )
            // Every reading, deliberately, where this used to log only presence changes. That
            // restraint is exactly what hid a live failure: a friend held an object up while
            // staying in view the whole time, so by the old definition nothing ever "changed" and
            // the log had nothing to say about the frames that mattered. One line per second is a
            // price worth paying to be able to answer "what did it actually see, and when".
            RockyLog.write(
                "camera: #\(sample.seq) judged in \(Int(sample.latency * 1000))ms — person=\(reading.personPresent)"
                    + (reading.bearing.map { String(format: " bearing=%.2f", $0) } ?? "")
                    + " scene=\(reading.scene ?? "(none)")"
            )
            lastSample = sample
            lastError = nil
        } catch {
            guard isRunning else {
                RockyLog.write("camera: detection ended after camera stopped")
                return
            }
            lastError = error.localizedDescription
            RockyLog.write("camera: detection failed: \(error.localizedDescription)")
        }
    }

    private func handleLookFrame(
        jpegData: Data, capturedAt: Date, generation: Int, seq: Int
    ) async {
        defer { throttle.withLock { $0.lookInFlight = false } }
        guard isRunning else { return }
        RockyLog.write(
            "camera: explicit look g\(generation) captured at \(Self.timestamp(capturedAt))"
        )
        do {
            let reading = try await lookVision.read(frame: jpegData)
            // A newer request superseded this one while it was being judged. Its result may be a
            // valid observation, but it cannot satisfy that newer request's freshness contract.
            let stillCurrent = throttle.withLock { $0.lookGeneration == generation }
            guard stillCurrent else {
                RockyLog.write("camera: explicit look g\(generation) discarded (superseded)")
                return
            }
            let sample = VisionSample(
                seq: seq, capturedAt: capturedAt, judgedAt: Date(), reading: reading
            )
            RockyLog.write(
                "camera: explicit look g\(generation) → #\(sample.seq) judged in \(Int(sample.latency * 1000))ms — "
                    + (reading.scene ?? reading.person ?? "(nothing described)")
            )
            lastSample = sample
            lastError = nil
        } catch {
            guard isRunning else {
                RockyLog.write("camera: explicit look g\(generation) ended after camera stopped")
                return
            }
            lastError = error.localizedDescription
            RockyLog.write("camera: explicit look g\(generation) failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func timestamp(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }
}

extension PersonCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let capturedAt = Date()
        let decision = throttle.withLock {
            state -> (passive: Bool, lookGeneration: Int?, sampleSeq: Int?) in
            if let after = state.lookAfter, capturedAt > after, !state.lookInFlight {
                state.lookAfter = nil
                state.lookInFlight = true
                state.sampleSeq += 1
                // The explicit lane wins this frame. Spending the same JPEG on passive inference
                // too would double network work at the exact moment voice is waiting for sight.
                return (false, state.lookGeneration, state.sampleSeq)
            }
            guard !state.inFlight,
                capturedAt.timeIntervalSince(state.lastSampleAt) >= Self.sampleInterval
            else { return (false, nil, nil) }
            state.lastSampleAt = capturedAt
            state.inFlight = true
            state.sampleSeq += 1
            return (true, nil, state.sampleSeq)
        }
        guard decision.passive || decision.lookGeneration != nil else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throttle.withLock {
                if decision.passive { $0.inFlight = false }
                if decision.lookGeneration != nil { $0.lookInFlight = false }
            }
            RockyLog.write("camera: sampled frame had no image buffer")
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpegData = Self.ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else {
            throttle.withLock {
                if decision.passive { $0.inFlight = false }
                if decision.lookGeneration != nil { $0.lookInFlight = false }
            }
            RockyLog.write(
                "camera: JPEG conversion failed for \(decision.lookGeneration == nil ? "passive" : "explicit") frame"
            )
            return
        }

        Task { @MainActor [weak self] in
            if decision.passive, let seq = decision.sampleSeq {
                await self?.handleFrame(
                    jpegData: jpegData, capturedAt: capturedAt, seq: seq
                )
            } else if let generation = decision.lookGeneration, let seq = decision.sampleSeq {
                await self?.handleLookFrame(
                    jpegData: jpegData, capturedAt: capturedAt, generation: generation, seq: seq
                )
            }
        }
    }
}
