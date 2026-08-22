import AVFoundation
import Foundation

/// Owns the front camera and turns it into a slow trickle of person-detection judgments.
///
/// The front camera, not the rear one: the phone's screen shows Rocky's face outward
/// (`OrbView` in `ContentView`), so the camera on the same side is the one pointed at whoever
/// Rocky is looking at.
///
/// This never records or persists a frame. Each captured photo lives only long enough to be
/// downscaled, sent to `PersonVision`, and discarded -- there is no video file, no photo-library
/// write, and nothing written to disk. The session itself only exists between `start()` and
/// `stop()`, both driven by an explicit, visible control in the UI (see `PersonCameraView`), never
/// started implicitly by the rest of the app coming up.
@MainActor
final class PersonCamera: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastDetection: PersonDetection?
    @Published private(set) var lastError: String?
    /// True while a captured frame is out being judged, so the next timer tick can skip rather
    /// than pile a second request on top of a slow one.
    @Published private(set) var isDetecting = false

    /// How often to sample a frame. A person doesn't need 30fps reasoning about them -- this is
    /// a bearing check, not a video call -- and every tick is a paid API call.
    private static let sampleInterval: TimeInterval = 2.5

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let vision = PersonVision()
    private var sampleTimer: Task<Void, Never>?
    private var configured = false

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Requests camera access if needed, configures the front camera once, and starts the
    /// sampling loop. Safe to call again while already running.
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
            return
        }

        if !configured {
            guard configure() else {
                lastError = "no front camera available on this device"
                return
            }
            configured = true
        }

        session.startRunning()
        isRunning = true
        sampleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sampleInterval))
                guard !Task.isCancelled else { return }
                self?.captureSample()
            }
        }
    }

    func stop() {
        sampleTimer?.cancel()
        sampleTimer = nil
        session.stopRunning()
        vision.disconnect()
        isRunning = false
        isDetecting = false
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input),
            session.canAddOutput(photoOutput)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        session.addOutput(photoOutput)
        session.commitConfiguration()
        return true
    }

    private func captureSample() {
        guard isRunning, !isDetecting else { return }
        isDetecting = true
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func handleCapturedPhoto(jpegData: Data?, errorDescription: String?) async {
        defer { isDetecting = false }
        if let errorDescription {
            lastError = errorDescription
            return
        }
        guard let jpegData else {
            lastError = "camera produced no image data"
            return
        }
        do {
            let detection = try await vision.detectPerson(in: jpegData)
            lastDetection = detection
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension PersonCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Pulled out here, inside the nonisolated delegate call, because AVCapturePhoto itself
        // isn't Sendable and can't cross into the @MainActor task below -- only the plain Data and
        // String extracted from it can.
        let jpegData = photo.fileDataRepresentation()
        let errorDescription = error?.localizedDescription
        Task { @MainActor in
            await handleCapturedPhoto(jpegData: jpegData, errorDescription: errorDescription)
        }
    }
}
