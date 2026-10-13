import Foundation
import Network

/// Talks only to the disposable step19 qualification payload, never to Rocky's normal motor path.
/// A hello handshake prevents a tap from sending motion to an unidentified service. One pulse per
/// view lifetime keeps this a measurement, not an unbounded manual steering control.
@MainActor
final class BoardTimedTurnController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var hasRun = false
    @Published private(set) var status = "Board-timed test ready · one 200 ms pulse"

    private var connection: NWConnection?
    private var buffer = ""
    private var timeout: Task<Void, Never>?
    private var initialForward: SIMD2<Double>?
    private let pulseID = UUID().uuidString

    func turnDegrees(probe: ARKitPoseProbe) -> Double? {
        guard let initialForward, let current = probe.lastForwardXZ else { return nil }
        return MotorPulsePolicy.headingChangeDegrees(from: initialForward, to: current)
    }

    func start(behavior: BehaviorMonitor, probe: ARKitPoseProbe) {
        guard !isBusy, !hasRun else { return }
        guard probe.isRunning, probe.mode == "scene-depth", probe.tracking == "normal",
              probe.lastForwardXZ != nil,
              let poseAt = probe.lastPoseAt, Date().timeIntervalSince(poseAt) < 0.4,
              let depthAt = probe.lastDepthAt, Date().timeIntervalSince(depthAt) < 0.4 else {
            status = "Wait for fresh normal ARKit and depth"
            return
        }
        guard let host = behavior.host ?? UserDefaults.standard.string(forKey: "behaviorHost"),
              !host.isEmpty else {
            status = "No saved robot address; reconnect Rocky first"
            return
        }
        isBusy = true
        status = "Connecting to board-timed test…"
        buffer = ""
        let link = NWConnection(host: NWEndpoint.Host(host), port: 8770, using: .tcp)
        connection = link
        link.stateUpdateHandler = { [weak self, weak probe] state in
            Task { @MainActor in
                guard let self, self.connection === link, let probe else { return }
                switch state {
                case .ready:
                    self.send(["type": "hello", "clock_only": true])
                    self.receive(probe: probe)
                case .failed(let error):
                    self.fail("Board test connection failed: \(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        link.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.fail("Board test timed out; pulse may have run if it was sent")
        }
    }

    func stop(probe: ARKitPoseProbe) {
        guard connection != nil else { return }
        send(["type": "stop", "id": pulseID])
        probe.mark("board-timed-turn-person-stop")
        // Disconnect is a second stop path in the disposable payload. The board also has its
        // own 200 ms duration, so this is not the only safety boundary.
        connection?.cancel()
        connection = nil
        timeout?.cancel()
        timeout = nil
        isBusy = false
        status = "Board test stop requested"
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        connection?.send(content: Data(line.utf8), completion: .idempotent)
    }

    private func receive(probe: ARKitPoseProbe) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak probe] data, _, done, error in
            Task { @MainActor in
                guard let self, let probe, self.connection != nil else { return }
                if let data { self.ingest(data, probe: probe) }
                if done || error != nil {
                    if self.isBusy { self.fail("Board test disconnected; local timer should stop pulse") }
                } else {
                    self.receive(probe: probe)
                }
            }
        }
    }

    private func ingest(_ data: Data, probe: ARKitPoseProbe) {
        buffer += String(decoding: data, as: UTF8.self)
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let event = message["event"] as? String else { continue }
            switch event {
            case "hello":
                guard message["service"] as? String == "rocky-navigation-qualification",
                      message["clock_only"] as? Bool == true else {
                    fail("Unexpected board test service; no pulse sent")
                    return
                }
                guard !hasRun else { continue }
                hasRun = true
                initialForward = probe.lastForwardXZ
                status = "Board pulse requested · 33 RPM for 200 ms"
                probe.mark("board-timed-turn-sent")
                send([
                    "type": "motion", "id": pulseID, "kind": "spin",
                    "rpm": 33, "duration_ms": 200, "direction": 1,
                ])
            case "motion_start":
                guard message["id"] as? String == pulseID else { continue }
                probe.mark("board-timed-turn-start t=\(message["t"] ?? "?")")
                status = "Board reports turn started"
            case "motion_end":
                guard message["id"] as? String == pulseID else { continue }
                let reason = message["reason"] as? String ?? "unknown"
                let start = (message["started_t"] as? NSNumber)?.intValue
                let end = (message["t"] as? NSNumber)?.intValue
                let reportSpan = start.flatMap { s in end.map { $0 - s } }
                let deadlineLate = (message["deadline_late_ms"] as? NSNumber)?.intValue
                let startReturn = (message["start_return_t"] as? NSNumber)?.intValue
                let stopCall = (message["stop_call_t"] as? NSNumber)?.intValue
                let stopReturn = (message["stop_return_t"] as? NSNumber)?.intValue
                probe.mark(
                    "board-timed-turn-end: \(reason) report_span_ms=\(reportSpan ?? -1) "
                        + "deadline_late_ms=\(deadlineLate ?? -1) "
                        + "started_t=\(start ?? -1) start_return_t=\(startReturn ?? -1) "
                        + "stop_call_t=\(stopCall ?? -1) stop_return_t=\(stopReturn ?? -1)"
                )
                status = "Board reports \(reason) · span \(reportSpan ?? -1) ms (includes motor calls)"
                isBusy = false
                timeout?.cancel()
                timeout = nil
                connection?.cancel()
                connection = nil
            case "refused":
                fail("Board refused: \(message["reason"] ?? "unknown")")
            default:
                break
            }
        }
    }

    private func fail(_ reason: String) {
        timeout?.cancel()
        timeout = nil
        connection?.cancel()
        connection = nil
        isBusy = false
        status = reason
    }
}
