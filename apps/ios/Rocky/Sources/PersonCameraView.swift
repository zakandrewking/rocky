import AVFoundation
import SwiftUI

/// Wraps `AVCaptureVideoPreviewLayer` -- SwiftUI has no native camera preview, and this is the
/// standard bridge for it.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// What Rocky sees: a live front-camera preview with a marker over the last detected person's
/// bearing.
///
/// `PersonCamera` starts and stops on its own, tied to the voice conversation's lifecycle (see
/// its header) -- this view is a window onto that, not the switch for it. Dismissing this sheet
/// leaves the camera running exactly as it was; the manual button below is a within-conversation
/// override, for anyone who wants Rocky's eyes off without ending the conversation to do it.
/// Nothing here is recorded: `PersonCamera` discards each frame right after judging it.
struct PersonCameraView: View {
    @ObservedObject var camera: PersonCamera
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                RockyTheme.ink.ignoresSafeArea()

                if camera.isRunning {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()
                        .overlay(alignment: .center) { bearingMarker }
                }

                VStack {
                    Spacer()
                    statusPanel
                }
                .padding(16)
            }
            .navigationTitle("What Rocky sees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var bearingMarker: some View {
        if let bearing = camera.lastDetection?.bearing {
            GeometryReader { geo in
                let x = geo.size.width * (0.5 + bearing / 2)
                Circle()
                    .stroke(RockyTheme.amberBright, lineWidth: 3)
                    .frame(width: 64, height: 64)
                    .position(x: x, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            if let error = camera.lastError {
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RockyTheme.rust.opacity(0.9))
            }
            controlButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(RockyTheme.deep.opacity(0.9))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).stroke(RockyTheme.mint.opacity(0.14))
                }
        }
    }

    private var statusLine: some View {
        Group {
            if !camera.isRunning {
                Text("camera: off")
            } else if let detection = camera.lastDetection, detection.personPresent {
                Text("person seen\(detection.description.map { ": \($0)" } ?? "")")
            } else if camera.isDetecting {
                Text("looking…")
            } else {
                Text("no person in view")
            }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundStyle(RockyTheme.mintBright.opacity(0.86))
    }

    private var controlButton: some View {
        Button {
            Task {
                if camera.isRunning { camera.stop() } else { await camera.start() }
            }
        } label: {
            Text(camera.isRunning ? "Stop camera" : "Start camera")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(RockyTheme.amberBright)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(RockyTheme.ink.opacity(0.7))
                        .overlay { Capsule().stroke(RockyTheme.amber.opacity(0.4)) }
                }
        }
        .buttonStyle(.plain)
    }
}
