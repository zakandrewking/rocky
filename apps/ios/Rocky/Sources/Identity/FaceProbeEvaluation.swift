import Foundation

/// Ground truth is supplied by the person running the experiment, never inferred from a score.
struct FaceProbeEvaluation: Sendable {
    enum CaptureKind: String, Identifiable, CaseIterable, Sendable {
        case reference, samePerson, differentPerson
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reference: "Capture reference"
            case .samePerson: "Same person"
            case .differentPerson: "Different person"
            }
        }
    }

    struct Trial: Identifiable, Sendable {
        let id = UUID()
        let kind: CaptureKind
        let distance: Double
        let milliseconds: Double
    }

    private(set) var reference: FaceFeaturePrintDescriptor?
    private(set) var trials: [Trial] = []
    private(set) var referenceMilliseconds: Double?
    static let maximumTrials = 100

    mutating func add(_ measurement: FaceFeaturePrintMeasurement, as kind: CaptureKind) throws {
        if kind == .reference {
            reference = measurement.descriptor
            referenceMilliseconds = measurement.elapsedMilliseconds
            trials = []
            return
        }
        guard let reference else { throw EvaluationError.missingReference }
        guard trials.count < Self.maximumTrials else { throw EvaluationError.trialLimit }
        let distance = try reference.distance(to: measurement.descriptor)
        guard distance.isFinite, measurement.elapsedMilliseconds.isFinite else {
            throw EvaluationError.invalidMeasurement
        }
        trials.append(Trial(kind: kind, distance: distance, milliseconds: measurement.elapsedMilliseconds))
    }

    var sameDistances: [Double] { trials.filter { $0.kind == .samePerson }.map(\.distance) }
    var differentDistances: [Double] { trials.filter { $0.kind == .differentPerson }.map(\.distance) }

    /// These are individual, user-paced captures. Do not describe these as a warm inference benchmark.
    func capturePercentile(_ fraction: Double) -> Double? {
        let sorted = trials.map(\.milliseconds).sorted()
        guard !sorted.isEmpty else { return nil }
        let index = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
        return sorted[index]
    }

    enum EvaluationError: LocalizedError {
        case missingReference, trialLimit, invalidMeasurement
        var errorDescription: String? {
            switch self {
            case .missingReference: "Capture a reference first."
            case .trialLimit: "This trial has 100 comparisons. Reset to start another."
            case .invalidMeasurement: "The model returned an invalid measurement. Retake the photo."
            }
        }
    }
}
