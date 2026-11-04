import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class FaceProbeLabModel: ObservableObject {
    @Published private(set) var evaluation = FaceProbeEvaluation()
    @Published private(set) var busy = false
    @Published var error: String?
    private(set) var generation = 0
    private var work: Task<Void, Never>?

    @discardableResult
    func capture(_ data: Data, as kind: FaceProbeEvaluation.CaptureKind,
                 generation expectedGeneration: Int) -> Task<Void, Never>? {
        guard !busy, expectedGeneration == generation else { return nil }
        error = nil
        busy = true
        let epoch = generation
        work = Task { [weak self] in
            do {
                // Only encoded image bytes cross isolation. Vision and Core Image stay entirely
                // on this worker; no camera or audio callback waits for extraction.
                let measurement = try await Task.detached(priority: .userInitiated) {
                    try FaceProbeCapture.measure(data)
                }.value
                guard let self, epoch == self.generation else { return }
                try self.evaluation.add(measurement, as: kind)
                self.busy = false
                self.work = nil
            } catch {
                guard let self, epoch == self.generation else { return }
                self.error = error.localizedDescription
                self.busy = false
                self.work = nil
            }
        }
        return work
    }

    func reset() {
        generation += 1
        work?.cancel()
        work = nil
        evaluation = FaceProbeEvaluation()
        busy = false
        error = nil
    }
}

struct FaceProbeLab: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: FaceProbeLabModel
    @ObservedObject var friends: FriendStore
    @State private var captureKind: CaptureRequest?
    @State private var authorizing = false
    @State private var permissionGeneration = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Test whether Rocky can tell faces apart across angles and lighting.")
                    Text("Photos are processed on this phone, then discarded. Test captures are temporary unless you choose Remember this face below.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Conversation is paused while you test. Resume it from the orb afterward.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("1 · Reference") {
                    Button(model.evaluation.reference == nil ? "Capture reference" : "Replace reference & clear comparisons") {
                        prepare(.reference)
                    }
                    if let reference = model.evaluation.reference {
                        Text("Reference ready · \(reference.values.count) values")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busy || authorizing)
                FriendControls(store: friends, reference: model.evaluation.reference)
                    .disabled(model.busy)
                Section("2 · Compare") {
                    Text("Choose who is in the next photo. For the same person, vary angle, distance or lighting. For a different person, keep similar framing and background.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Capture same person") { prepare(.samePerson) }
                        .disabled(model.evaluation.reference == nil)
                    Button("Capture different person") { prepare(.differentPerson) }
                        .disabled(model.evaluation.reference == nil)
                    if model.busy { ProgressView("Measuring face on this phone…") }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
                .disabled(model.busy || authorizing)
                Section("Measurements") {
                    Text("Smaller distance means more similar. These are measurements, not a recognition decision.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Same person", value: range(model.evaluation.sameDistances))
                    LabeledContent("Different person", value: range(model.evaluation.differentDistances))
                    if let same = model.evaluation.sameDistances.max(),
                       let different = model.evaluation.differentDistances.min() {
                        Text(same < different
                             ? "The measured ranges are separate so far. More people and conditions are needed."
                             : "The measured ranges overlap. This baseline cannot separate these examples reliably.")
                            .font(.footnote)
                    }
                    if let p50 = model.evaluation.capturePercentile(0.5),
                       let p95 = model.evaluation.capturePercentile(0.95) {
                        LabeledContent("Feature print p50 / p95", value: "\(Int(p50.rounded())) / \(Int(p95.rounded())) ms")
                        Text("\(model.evaluation.trials.count) comparisons · user-paced captures, not a sustained benchmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.evaluation.trials.reversed()) { trial in
                        LabeledContent(trial.kind.title, value: String(format: "%.4f · %.0f ms", trial.distance, trial.milliseconds))
                    }
                }
                Section {
                    Button("Reset all test data", role: .destructive) {
                        permissionGeneration += 1
                        captureKind = nil
                        model.reset()
                    }
                    Text("Experimental Apple Vision revision 2 · \(FaceProbeCapture.preprocessing). Reset clears test data only. Saved friends remain until you forget them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Friends & face test")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { clearAndClose() }
                }
            }
        }
        .fullScreenCover(item: $captureKind) { request in
            FaceProbeCamera { data in
                captureKind = nil
                if let data { model.capture(data, as: request.kind, generation: request.generation) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clearAndClose() }
        }
        .onDisappear {
            permissionGeneration += 1
        }
    }

    private func range(_ values: [Double]) -> String {
        guard let low = values.min(), let high = values.max() else { return "No captures" }
        return String(format: "%.4f–%.4f (%d)", low, high, values.count)
    }

    private struct CaptureRequest: Identifiable {
        let id = UUID()
        let kind: FaceProbeEvaluation.CaptureKind
        let generation: Int
    }

    private func clearAndClose() {
        permissionGeneration += 1
        captureKind = nil
        model.reset()
        dismiss()
    }

    private func prepare(_ kind: FaceProbeEvaluation.CaptureKind) {
        guard !authorizing, !model.busy else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              UIImagePickerController.isCameraDeviceAvailable(.front) else {
            model.error = "A front camera is required. Use the physical iPhone for captures."
            return
        }
        authorizing = true
        let epoch = permissionGeneration
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard epoch == permissionGeneration else { authorizing = false; return }
            authorizing = false
            if allowed {
                model.error = nil
                captureKind = CaptureRequest(kind: kind, generation: model.generation)
            } else {
                model.error = "Allow camera access for Rocky in Settings to run this test."
            }
        }
    }
}

/// Apple's camera UI owns only an explicit still capture. Nothing is added to Photos, and the
/// normalized image bytes are passed straight to the worker with no file or network operation.
private struct FaceProbeCamera: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var onCapture: ((Data?) -> Void)?
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { finish(nil); return }
            // Drawing applies UIImage orientation. Bound the worker's input size and use scale 1
            // so a Retina display doesn't silently triple these dimensions.
            let scale = min(1, 1600 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            finish(normalized.jpegData(compressionQuality: 0.95))
        }
        private func finish(_ data: Data?) {
            let callback = onCapture
            onCapture = nil
            callback?(data)
        }
    }
}
