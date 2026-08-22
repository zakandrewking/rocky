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
    @Published private(set) var lastDetection: PersonDetection?
    @Published private(set) var lastError: String?
    /// True while a sampled frame is out being judged, so the throttle can skip rather than pile
    /// a second request on top of a slow one.
    @Published private(set) var isDetecting = false

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
    private let vision = PersonVision()
    private var configured = false

    /// Frames arrive on `videoQueue`, serially but off the main actor; detection state
    /// (`isDetecting`, `lastDetection`, ...) is main-actor-isolated. This lock is the one thing
    /// both sides may touch, so the throttle -- "are we already mid-request, and is it too soon
    /// since the last one" -- can be decided cheaply on the delivery queue before ever paying for
    /// a CVPixelBuffer → JPEG conversion on a frame that's going to be dropped anyway.
    private struct ThrottleState {
        var lastSampleAt = Date.distantPast
        var inFlight = false
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
        throttle.withLock { $0 = ThrottleState() }
        session.startRunning()
        isRunning = true
        RockyLog.write("camera: started")
    }

    func stop() {
        session.stopRunning()
        vision.disconnect()
        isRunning = false
        isDetecting = false
        RockyLog.write("camera: stopped")
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

    private func handleFrame(jpegData: Data) async {
        defer { throttle.withLock { $0.inFlight = false } }
        guard isRunning else { return }
        isDetecting = true
        defer { isDetecting = false }
        do {
            let detection = try await vision.detectPerson(in: jpegData)
            // Logged only on a real change, the same restraint `RealtimeVoiceSession` applies to
            // vision context in the conversation -- a line every ~1s the whole time someone is
            // simply standing there would drown out everything else in session.log.
            if detection.personPresent != lastDetection?.personPresent {
                RockyLog.write(
                    "camera: \(detection.personPresent ? "person appeared (\(detection.description ?? "no description"))" : "person left view")"
                )
            }
            lastDetection = detection
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            RockyLog.write("camera: detection failed: \(error.localizedDescription)")
        }
    }
}

extension PersonCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let shouldSample = throttle.withLock { state -> Bool in
            guard !state.inFlight, Date().timeIntervalSince(state.lastSampleAt) >= Self.sampleInterval
            else { return false }
            state.lastSampleAt = Date()
            state.inFlight = true
            return true
        }
        guard shouldSample else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throttle.withLock { $0.inFlight = false }
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpegData = Self.ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else {
            throttle.withLock { $0.inFlight = false }
            return
        }

        Task { @MainActor [weak self] in
            await self?.handleFrame(jpegData: jpegData)
        }
    }
}
