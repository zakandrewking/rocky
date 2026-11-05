import Foundation

struct FacePresence: Equatable, Sendable {
    enum Kind: String, Sendable { case off, nobody, unknown, multiple, recognized }
    var kind: Kind
    var friendID: UUID?
    var name: String?
    static let off = FacePresence(kind: .off)
}

/// Conservative MVP thresholds, deliberately not advertised as validated recognition accuracy.
/// Score per person (not per template), require an absolute match AND separation from runner-up.
enum FaceMatcher {
    static let maximumDistance = 0.32
    static let minimumMargin = 0.10
    struct Assessment {
        var friend: FriendProfile?
        var reason: String
        var nearestDistance: Double?
    }
    static func match(_ descriptor: FaceFeaturePrintDescriptor, friends: [FriendProfile]) -> FriendProfile? {
        assess(descriptor, friends: friends).friend
    }
    static func assess(_ descriptor: FaceFeaturePrintDescriptor, friends: [FriendProfile]) -> Assessment {
        let ranked = friends.compactMap { friend -> (FriendProfile, Double)? in
            let distances = friend.templates.compactMap { try? descriptor.distance(to: $0) }
                .filter(\.isFinite)
            guard let distance = distances.min() else { return nil }
            return (friend, distance)
        }.sorted { $0.1 < $1.1 }
        guard let first = ranked.first else { return Assessment(reason: "incompatible templates") }
        guard first.1 <= maximumDistance else {
            return Assessment(reason: "outside match threshold", nearestDistance: first.1)
        }
        guard ranked.count < 2 || ranked[1].1 - first.1 >= minimumMargin else {
            return Assessment(reason: "ambiguous match", nearestDistance: first.1)
        }
        return Assessment(friend: first.0, reason: "candidate match", nearestDistance: first.1)
    }
}

struct FaceConsensus {
    private var candidate: UUID?
    private var streak = 0
    private var lastAt: Date?
    mutating func observe(_ id: UUID?, at: Date) -> Bool {
        guard lastAt.map({ at > $0 }) ?? true else { return false }
        if candidate == id, let lastAt, at.timeIntervalSince(lastAt) <= 2.5 {
            streak += 1
        } else { candidate = id; streak = 1 }
        lastAt = at
        return id != nil && streak >= 3
    }
}

@MainActor
final class LiveFaceRecognition: ObservableObject {
    @Published private(set) var presence: FacePresence = .off
    @Published private(set) var diagnostic = "waiting for camera"
    /// Temporary in-app measurement, never written to the log or identity vault.
    @Published private(set) var nearestDistance: Double?
    var onChange: ((FacePresence) -> Void)?
    private var friends: [FriendProfile] = []
    private var generation = 0
    private var consensus = FaceConsensus()
    private var expiry: Task<Void, Never>?
    private var validAfter = Date.distantPast
    private var lastProcessedAt = Date.distantPast
    private var lastDiagnosticAt = Date.distantPast

    func configure(_ friends: [FriendProfile]) { self.friends = friends; reset() }
    func reset() {
        generation += 1
        validAfter = Date()
        lastProcessedAt = .distantPast
        consensus = FaceConsensus()
        expiry?.cancel()
        expiry = nil
        diagnostic = friends.isEmpty ? "no saved friends" : "waiting for camera"
        nearestDistance = nil
        publish(.off)
    }
    func process(_ data: Data, capturedAt: Date) async {
        guard !friends.isEmpty, capturedAt >= validAfter, capturedAt > lastProcessedAt else { return }
        let epoch = generation
        let result = await Task.detached(priority: .utility) { () -> Result<FaceFeaturePrintMeasurement, Error> in
            Result { try FaceProbeCapture.measure(data) }
        }.value
        guard epoch == generation else { return }
        guard Date().timeIntervalSince(capturedAt) < 2 else {
            report("processing too slow")
            return
        }
        guard capturedAt > lastProcessedAt else { return }
        lastProcessedAt = capturedAt
        let proposed: FacePresence
        switch result {
        case .success(let measurement):
            let assessment = FaceMatcher.assess(measurement.descriptor, friends: friends)
            nearestDistance = assessment.nearestDistance
            let friend = assessment.friend
            let confirmed = consensus.observe(friend?.id, at: capturedAt)
            if confirmed, let friend {
                proposed = FacePresence(kind: .recognized, friendID: friend.id, name: friend.name)
            } else { proposed = FacePresence(kind: .unknown) }
            report(confirmed ? "recognized" : assessment.reason)
        case .failure(let error):
            nearestDistance = nil
            _ = consensus.observe(nil, at: capturedAt)
            switch error as? FaceProbeCapture.CaptureError {
            case .noFace: proposed = FacePresence(kind: .nobody)
            case .multipleFaces: proposed = FacePresence(kind: .multiple)
            default: proposed = FacePresence(kind: .unknown)
            }
            if let captureError = error as? FaceProbeCapture.CaptureError {
                report(captureError.localizedDescription)
            } else { report("feature extraction failed") }
        }
        publish(proposed)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.consensus = FaceConsensus()
            self.nearestDistance = nil
            self.publish(FacePresence(kind: .unknown))
        }
    }
    private func report(_ message: String) {
        let changed = diagnostic != message
        diagnostic = message
        if changed || Date().timeIntervalSince(lastDiagnosticAt) >= 5 {
            lastDiagnosticAt = Date()
            // Categories only: no names, images, vectors, or biometric distance scores.
            RockyLog.write("faces: sample — \(message)")
        }
    }
    private func publish(_ next: FacePresence) {
        guard presence != next else { return }
        presence = next
        RockyLog.write("faces: \(next.kind.rawValue)")
        onChange?(next)
    }
}
