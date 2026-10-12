import Foundation

/// One deliberately small, operator-started motor test. This is not path planning or obstacle
/// avoidance: it uses the existing newest-state manual-drive transport and its board watchdog.
enum ForwardPulsePolicy {
    static let throttle = 0.22
    static let duration: TimeInterval = 0.6
    static let maxCameraTravelMeters = 0.2
    static let maxSampleAge: TimeInterval = 0.4

    struct Snapshot {
        let linked: Bool
        let still: Bool
        let probeRunning: Bool
        let depthMode: Bool
        let trackingNormal: Bool
        let poseAge: TimeInterval
        let depthAge: TimeInterval
        let cameraTravelMeters: Double
    }

    static func stopReason(_ state: Snapshot) -> String? {
        if !state.linked { return "robot link lost" }
        if !state.still { return "robot not in still mode" }
        if !state.probeRunning { return "ARKit stopped" }
        if !state.depthMode { return "LiDAR depth mode required" }
        if !state.trackingNormal { return "ARKit tracking limited" }
        if state.poseAge > maxSampleAge { return "ARKit pose stale" }
        if state.depthAge > maxSampleAge { return "LiDAR depth stale" }
        if state.cameraTravelMeters >= maxCameraTravelMeters { return "camera moved 0.2 m" }
        return nil
    }
}

@MainActor
final class ForwardPulseController: ObservableObject {
    @Published private(set) var isDriving = false
    @Published private(set) var status = "Ready for a short forward pulse"
    private var task: Task<Void, Never>?

    func start(behavior: BehaviorMonitor, probe: ARKitPoseProbe) {
        guard !isDriving else { return }
        guard let origin = probe.lastPositionMeters else {
            status = "Waiting for ARKit pose"
            return
        }
        if let reason = ForwardPulsePolicy.stopReason(
            snapshot(behavior: behavior, probe: probe, origin: origin)
        ) {
            status = "Cannot start: \(reason)"
            return
        }
        isDriving = true
        status = "Driving forward briefly…"
        probe.mark("auto-forward-start")
        send(throttle: ForwardPulsePolicy.throttle, active: true, correlated: true,
             behavior: behavior, probe: probe)
        task = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            var lastHeartbeat = start
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard self.isDriving else { return }
                if let reason = ForwardPulsePolicy.stopReason(
                    self.snapshot(behavior: behavior, probe: probe, origin: origin)
                ) {
                    self.finish(reason: reason, behavior: behavior, probe: probe)
                    return
                }
                let now = Date()
                if now.timeIntervalSince(start) >= ForwardPulsePolicy.duration {
                    self.finish(reason: "0.6 s limit", behavior: behavior, probe: probe)
                    return
                }
                if now.timeIntervalSince(lastHeartbeat) >= 0.18 {
                    self.send(throttle: ForwardPulsePolicy.throttle, active: true,
                              correlated: false,
                              behavior: behavior, probe: probe)
                    lastHeartbeat = now
                }
            }
        }
    }

    func emergencyStop(behavior: BehaviorMonitor, probe: ARKitPoseProbe) {
        if isDriving {
            finish(reason: "person stopped", behavior: behavior, probe: probe)
        } else {
            send(throttle: 0, active: false, correlated: true,
                 behavior: behavior, probe: probe)
            behavior.stopMoving()
            status = "Stop sent"
        }
    }

    private func finish(reason: String, behavior: BehaviorMonitor, probe: ARKitPoseProbe) {
        guard isDriving else { return }
        isDriving = false
        task?.cancel()
        task = nil
        send(throttle: 0, active: false, correlated: true,
             behavior: behavior, probe: probe)
        behavior.stopMoving()
        probe.mark("auto-forward-stop: \(reason)")
        status = "Stopped: \(reason)"
    }

    private func send(
        throttle: Double, active: Bool, correlated: Bool,
        behavior: BehaviorMonitor, probe: ARKitPoseProbe
    ) {
        behavior.setManualDrive(
            throttle: throttle, steering: 0, active: active, correlated: correlated
        )
        probe.recordDrive(
            throttle: throttle, steering: 0, active: active, correlated: correlated
        )
    }

    private func snapshot(
        behavior: BehaviorMonitor, probe: ARKitPoseProbe, origin: SIMD3<Float>
    ) -> ForwardPulsePolicy.Snapshot {
        let position = probe.lastPositionMeters ?? origin
        let travel = hypot(
            Double(position.x - origin.x), Double(position.z - origin.z)
        )
        return .init(
            linked: behavior.controlsConnected,
            still: behavior.mood == "still",
            probeRunning: probe.isRunning,
            depthMode: probe.mode == "scene-depth",
            trackingNormal: probe.tracking == "normal",
            poseAge: probe.lastPoseAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            depthAge: probe.lastDepthAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            cameraTravelMeters: travel
        )
    }
}
