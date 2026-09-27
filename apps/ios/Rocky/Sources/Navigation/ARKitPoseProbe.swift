import ARKit
import AVFoundation
import Foundation

/// An observational, rear-camera experiment. It never owns or sends motor commands.
/// Manual drive stays with BehaviorMonitor and its existing UDP/watchdog path.
@MainActor
final class ARKitPoseProbe: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var tracking = "off"
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastPosition = "—"
    @Published private(set) var lastError: String?
    @Published private(set) var fileName: String?
    @Published private(set) var mode = "standard"

    private let session = ARSession()
    private var logHandle: FileHandle?
    private var lastLoggedFrameTime = -Double.infinity
    private var framesSinceLog = 0
    private var startGeneration = 0
    private var isStarting = false

    func start(useSceneDepth: Bool = false, robotConnected: Bool = false) async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        defer { isStarting = false }
        lastError = nil
        guard ARWorldTrackingConfiguration.isSupported else {
            lastError = "ARKit world tracking is unavailable on this iPhone"
            return
        }
        if useSceneDepth && !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            lastError = "This device cannot provide ARKit scene depth"
            return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        // Camera permission can suspend this method. Voice startup/backgrounding may cancel the
        // probe while the system prompt is open; never start ARKit after that cancellation.
        guard generation == startGeneration else { return }
        guard authorized else {
            lastError = "Camera access is required for the ARKit probe"
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "navigation-probe-\(stamp).jsonl"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            lastError = "Could not create navigation probe log"
            return
        }
        logHandle = handle
        fileName = name
        sampleCount = 0
        lastLoggedFrameTime = -Double.infinity
        framesSinceLog = 0
        tracking = "initializing"
        mode = useSceneDepth ? "scene-depth" : "standard"
        isRunning = true
        session.delegate = self
        session.delegateQueue = .main
        write([
            "type": "start", "camera": "rear", "source": "ARWorldTrackingConfiguration",
            "mode": mode, "robot_connected": robotConnected,
        ])
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if useSceneDepth { config.frameSemantics.insert(.sceneDepth) }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        RockyLog.write("navigation probe: started \(name)")
    }

    func stop(reason: String) {
        startGeneration += 1
        guard isRunning else { return }
        // Stop callbacks before closing the log; never leave a stale AR session owning the camera.
        session.pause()
        session.delegate = nil
        write(["type": "stop", "reason": reason])
        try? logHandle?.close()
        logHandle = nil
        isRunning = false
        tracking = "off"
        RockyLog.write("navigation probe: stopped (\(reason))")
    }

    func mark(_ label: String) {
        guard isRunning else { return }
        write(["type": "mark", "label": label])
    }

    func recordDrive(throttle: Double, steering: Double, active: Bool, correlated: Bool) {
        guard isRunning else { return }
        write([
            "type": "drive", "throttle": throttle, "steering": steering,
            "active": active, "correlated": correlated,
        ])
    }

    func recordRobotConnection(_ connected: Bool) {
        guard isRunning else { return }
        write(["type": "robot_link", "connected": connected])
    }

    private func write(_ fields: [String: Any]) {
        guard let logHandle else { return }
        var entry = fields
        entry["wall_time"] = ISO8601DateFormatter().string(from: Date())
        entry["uptime_s"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let newline = "\n".data(using: .utf8) else { return }
        do {
            try logHandle.write(contentsOf: data)
            try logHandle.write(contentsOf: newline)
        } catch {
            lastError = "Navigation log write failed: \(error.localizedDescription)"
            self.logHandle = nil
            try? logHandle.close()
            stop(reason: "log error")
        }
    }
}

extension ARKitPoseProbe: @preconcurrency ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        let state: String
        switch frame.camera.trackingState {
        case .normal: state = "normal"
        case .notAvailable: state = "unavailable"
        case .limited(let reason): state = "limited:\(reason)"
        }
        if tracking != state { tracking = state }
        framesSinceLog += 1
        // The experiment records 10 Hz while leaving ARKit free to track at its own frame rate.
        guard frame.timestamp - lastLoggedFrameTime >= 0.1 else { return }
        lastLoggedFrameTime = frame.timestamp
        let callbackCount = framesSinceLog
        framesSinceLog = 0
        let transform = frame.camera.transform
        let x = Double(transform.columns.3.x)
        let y = Double(transform.columns.3.y)
        let z = Double(transform.columns.3.z)
        let forwardX = -Double(transform.columns.2.x)
        let forwardZ = -Double(transform.columns.2.z)
        let matrix = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w,
        ].map(Double.init)
        lastPosition = String(format: "x %.2f · z %.2f m", x, z)
        sampleCount += 1
        write([
            "type": "pose", "frame_time_s": frame.timestamp, "tracking": state,
            "frame_callbacks_since_last": callbackCount,
            "x_m": x, "y_m": y, "z_m": z,
            "forward_x": forwardX, "forward_z": forwardZ,
            "camera_matrix_col_major": matrix,
            "scene_depth_available": frame.sceneDepth != nil,
        ])
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lastError = "ARKit: \(error.localizedDescription)"
        stop(reason: "ARKit error")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        lastError = "ARKit camera session interrupted"
        stop(reason: "camera interrupted")
    }
}
