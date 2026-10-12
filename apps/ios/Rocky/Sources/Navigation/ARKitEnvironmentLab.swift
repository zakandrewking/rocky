import ARKit
import RealityKit
import SwiftUI

/// Shows the very same ARSession that the pose recorder observes. RealityKit's diagnostic dots
/// are ARKit's intermediate feature points, not a calibrated tracking-confidence score.
private struct ARKitCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.debugOptions = [.showFeaturePoints]
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}
}

struct ARKitEnvironmentLab: View {
    @ObservedObject var probe: ARKitPoseProbe
    @ObservedObject var behavior: BehaviorMonitor
    let close: () -> Void
    @State private var showDepth = true
    @StateObject private var motorPulse = MotorPulseController()

    var body: some View {
        ZStack {
            ARKitCameraView(session: probe.arSession)
                .ignoresSafeArea()

            if showDepth && probe.mode == "scene-depth" {
                ZStack {
                    Color.black
                    if let preview = probe.depthPreview {
                        Image(uiImage: preview)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    } else {
                        Text("Waiting for LiDAR depth…")
                            .foregroundStyle(.white)
                    }
                }
                .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ARKit · \(probe.mode)")
                        .foregroundStyle(RockyTheme.mintBright)
                    Text("tracking: \(probe.tracking)")
                        .foregroundStyle(probe.tracking == "normal" ? RockyTheme.mintBright : RockyTheme.amberBright)
                    Text("normal \(probe.normalTrackingPercent)% · features \(probe.featurePointCount) · samples \(probe.sampleCount)")
                    Text(probe.lastPosition)
                    Text(showDepth && probe.mode == "scene-depth"
                         ? "Depth: red near · blue far · dark low confidence"
                         : "Dots show ARKit landmarks, not a quality score")
                        .foregroundStyle(RockyTheme.mint.opacity(0.72))
                    if probe.mode == "scene-depth" {
                        Text(motorPulse.status)
                            .foregroundStyle(RockyTheme.amberBright)
                        if let turn = motorPulse.turnDegrees(probe: probe) {
                            Text(String(format: "ARKit turn Δ: %+.1f°", turn))
                                .foregroundStyle(RockyTheme.mintBright)
                        }
                        Text("Clear floor only · no obstacle avoidance")
                            .foregroundStyle(RockyTheme.rust)
                        if behavior.controlsConnected && behavior.mood != "still" {
                            Text("Pause voice; wait for robot: still")
                                .foregroundStyle(RockyTheme.amberBright)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .background(RockyTheme.ink.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                if probe.mode == "scene-depth" {
                    HStack {
                        Button("FORWARD TEST · 0.6s") {
                            motorPulse.start(.forward, behavior: behavior, probe: probe)
                        }
                        .disabled(
                            !behavior.controlsConnected || behavior.mood != "still"
                                || motorPulse.isDriving
                        )
                        .tint(RockyTheme.mint)
                        Button("RIGHT TURN · 0.5s") {
                            motorPulse.start(.rightTurn, behavior: behavior, probe: probe)
                        }
                        .disabled(
                            !behavior.controlsConnected || behavior.mood != "still"
                                || motorPulse.isDriving
                        )
                        .tint(RockyTheme.mint)
                    }
                    HStack {
                        Spacer()
                        Button("STOP ROBOT") {
                            motorPulse.emergencyStop(behavior: behavior, probe: probe)
                        }
                        .tint(RockyTheme.rust)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 13, design: .monospaced))
                }

                if probe.mode == "scene-depth" {
                    HStack {
                        Button("Camera") { showDepth = false }
                        Button("Depth") { showDepth = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RockyTheme.ink)
                    .font(.system(size: 13, design: .monospaced))
                }

                HStack {
                    Button("Mark trial") { probe.mark("trial") }
                    Spacer()
                    Button("Keep logging") {
                        motorPulse.emergencyStop(behavior: behavior, probe: probe)
                        close()
                    }
                    Button("End probe") {
                        motorPulse.emergencyStop(behavior: behavior, probe: probe)
                        probe.stop(reason: "person stopped")
                        close()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(RockyTheme.ink)
                .font(.system(size: 13, design: .monospaced))
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onChange(of: probe.isRunning) { _, running in
            if !running && motorPulse.isDriving {
                motorPulse.emergencyStop(behavior: behavior, probe: probe)
            }
        }
        .onChange(of: behavior.controlsConnected) { _, connected in
            if !connected && motorPulse.isDriving {
                motorPulse.emergencyStop(behavior: behavior, probe: probe)
            }
        }
        .onDisappear {
            if motorPulse.isDriving {
                motorPulse.emergencyStop(behavior: behavior, probe: probe)
            }
        }
    }
}
