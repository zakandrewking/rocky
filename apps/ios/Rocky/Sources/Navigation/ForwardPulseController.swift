import Foundation

/// One deliberately small, operator-started motor test. This is not path planning or obstacle
/// avoidance: it uses the existing newest-state manual-drive transport and its board watchdog.
enum MotorPulsePolicy {
    enum Motion {
        case forward
        case rightTurn

        var throttle: Double { self == .forward ? 0.22 : 0 }
        var steering: Double { self == .rightTurn ? 0.22 : 0 }
        var duration: TimeInterval { self == .forward ? 0.6 : 0.5 }
        var label: String { self == .forward ? "forward" : "right-turn" }
    }

    static let maxCameraTravelMeters = 0.2
    static let maxTurnCameraTravelMeters = 0.1
    static let maxTurnDegrees = 35.0
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
        let headingChangeDegrees: Double
    }

    static func stopReason(_ state: Snapshot, motion: Motion) -> String? {
        if !state.linked { return "robot link lost" }
        if !state.still { return "robot not in still mode" }
        if !state.probeRunning { return "ARKit stopped" }
        if !state.depthMode { return "LiDAR depth mode required" }
        if !state.trackingNormal { return "ARKit tracking limited" }
        if state.poseAge > maxSampleAge { return "ARKit pose stale" }
        if state.depthAge > maxSampleAge { return "LiDAR depth stale" }
        if motion == .forward && state.cameraTravelMeters >= maxCameraTravelMeters {
            return "camera moved 0.2 m"
        }
        if motion == .rightTurn {
            if state.cameraTravelMeters >= maxTurnCameraTravelMeters {
                return "camera moved 0.1 m"
            }
            if abs(state.headingChangeDegrees) >= maxTurnDegrees {
                return "camera turned 35°"
            }
        }
        return nil
    }

    static func headingChangeDegrees(from start: SIMD2<Double>, to current: SIMD2<Double>) -> Double {
        let cross = start.x * current.y - start.y * current.x
        let dot = start.x * current.x + start.y * current.y
        return atan2(cross, dot) * 180 / .pi
    }
}

@MainActor
final class MotorPulseController: ObservableObject {
    @Published private(set) var isDriving = false
    @Published private(set) var status = "Ready for a short motor pulse"
    private var turnStartForward: SIMD2<Double>?
    private var task: Task<Void, Never>?

    func turnDegrees(probe: ARKitPoseProbe) -> Double? {
        guard let turnStartForward, let current = probe.lastForwardXZ else { return nil }
        return MotorPulsePolicy.headingChangeDegrees(from: turnStartForward, to: current)
    }

    func start(_ motion: MotorPulsePolicy.Motion, behavior: BehaviorMonitor, probe: ARKitPoseProbe) {
        guard !isDriving else { return }
        guard let origin = probe.lastPositionMeters, let initialForward = probe.lastForwardXZ else {
            status = "Waiting for ARKit pose"
            return
        }
        if let reason = MotorPulsePolicy.stopReason(
            snapshot(behavior: behavior, probe: probe, origin: origin, initialForward: initialForward),
            motion: motion
        ) {
            status = "Cannot start: \(reason)"
            return
        }
        isDriving = true
        activeMotion = motion
        turnStartForward = motion == .rightTurn ? initialForward : nil
        status = motion == .forward ? "Driving forward briefly…" : "Turning right briefly…"
        probe.mark("auto-\(motion.label)-start")
        send(throttle: motion.throttle, steering: motion.steering, active: true, correlated: true,
             behavior: behavior, probe: probe)
        task = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            var lastHeartbeat = start
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard self.isDriving else { return }
                if let reason = MotorPulsePolicy.stopReason(
                    self.snapshot(behavior: behavior, probe: probe, origin: origin,
                                  initialForward: initialForward), motion: motion
                ) {
                    self.finish(reason: reason, motion: motion, behavior: behavior, probe: probe)
                    return
                }
                let now = Date()
                if now.timeIntervalSince(start) >= motion.duration {
                    self.finish(reason: "\(motion.duration) s limit", motion: motion,
                                behavior: behavior, probe: probe)
                    return
                }
                if now.timeIntervalSince(lastHeartbeat) >= 0.18 {
                    self.send(throttle: motion.throttle, steering: motion.steering, active: true,
                              correlated: false,
                              behavior: behavior, probe: probe)
                    lastHeartbeat = now
                }
            }
        }
    }

    func emergencyStop(behavior: BehaviorMonitor, probe: ARKitPoseProbe) {
        if isDriving {
            finish(reason: "person stopped", motion: activeMotion ?? .forward,
                   behavior: behavior, probe: probe)
        } else {
            send(throttle: 0, steering: 0, active: false, correlated: true,
                 behavior: behavior, probe: probe)
            behavior.stopMoving()
            status = "Stop requested"
        }
    }

    private var activeMotion: MotorPulsePolicy.Motion?

    private func finish(
        reason: String, motion: MotorPulsePolicy.Motion,
        behavior: BehaviorMonitor, probe: ARKitPoseProbe
    ) {
        guard isDriving else { return }
        isDriving = false
        task?.cancel()
        task = nil
        activeMotion = nil
        send(throttle: 0, steering: 0, active: false, correlated: true,
             behavior: behavior, probe: probe)
        behavior.stopMoving()
        probe.mark("auto-\(motion.label)-stop: \(reason)")
        status = "Stop requested: \(reason)"
    }

    private func send(
        throttle: Double, steering: Double, active: Bool, correlated: Bool,
        behavior: BehaviorMonitor, probe: ARKitPoseProbe
    ) {
        behavior.setManualDrive(
            throttle: throttle, steering: steering, active: active, correlated: correlated
        )
        probe.recordDrive(
            throttle: throttle, steering: steering, active: active, correlated: correlated
        )
    }

    private func snapshot(
        behavior: BehaviorMonitor, probe: ARKitPoseProbe, origin: SIMD3<Float>,
        initialForward: SIMD2<Double>
    ) -> MotorPulsePolicy.Snapshot {
        let position = probe.lastPositionMeters ?? origin
        let travel = hypot(
            Double(position.x - origin.x), Double(position.z - origin.z)
        )
        let heading = probe.lastForwardXZ.map {
            MotorPulsePolicy.headingChangeDegrees(from: initialForward, to: $0)
        } ?? 0
        return .init(
            linked: behavior.controlsConnected,
            still: behavior.mood == "still",
            probeRunning: probe.isRunning,
            depthMode: probe.mode == "scene-depth",
            trackingNormal: probe.tracking == "normal",
            poseAge: probe.lastPoseAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            depthAge: probe.lastDepthAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            cameraTravelMeters: travel,
            headingChangeDegrees: heading
        )
    }
}
