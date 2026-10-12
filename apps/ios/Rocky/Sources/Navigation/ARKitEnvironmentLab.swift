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
    let close: () -> Void

    var body: some View {
        ZStack {
            ARKitCameraView(session: probe.arSession)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ARKit · \(probe.mode)")
                        .foregroundStyle(RockyTheme.mintBright)
                    Text("tracking: \(probe.tracking)")
                        .foregroundStyle(probe.tracking == "normal" ? RockyTheme.mintBright : RockyTheme.amberBright)
                    Text("normal \(probe.normalTrackingPercent)% · features \(probe.featurePointCount) · samples \(probe.sampleCount)")
                    Text(probe.lastPosition)
                    Text("Dots show ARKit landmarks, not a quality score")
                        .foregroundStyle(RockyTheme.mint.opacity(0.72))
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .background(RockyTheme.ink.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                HStack {
                    Button("Mark trial") { probe.mark("trial") }
                    Spacer()
                    Button("Keep logging") { close() }
                    Button("Stop") {
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
    }
}
