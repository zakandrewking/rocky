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
        var nearestFriendID: UUID?
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
            return Assessment(reason: "outside match threshold", nearestDistance: first.1, nearestFriendID: first.0.id)
        }
        guard ranked.count < 2 || ranked[1].1 - first.1 >= minimumMargin else {
            return Assessment(reason: "ambiguous match", nearestDistance: first.1, nearestFriendID: first.0.id)
        }
        return Assessment(friend: first.0, reason: "candidate match", nearestDistance: first.1, nearestFriendID: first.0.id)
    }
}

/// Bounded scalar diagnostics, enabled at the user's request. Never retains frames or vectors.
struct FaceDistanceTrend {
    struct Summary { let count: Int; let minimum: Double; let mean: Double; let maximum: Double }
    private var count = 0
    private var total = 0.0
    private var minimum = Double.infinity
    private var maximum = 0.0
    private var lastReport = Date.distantPast

    mutating func record(_ distance: Double, at: Date) -> Summary? {
        guard distance.isFinite, distance >= 0 else { return nil }
        count += 1; total += distance
        minimum = min(minimum, distance); maximum = max(maximum, distance)
        guard at.timeIntervalSince(lastReport) >= 5 else { return nil }
        let summary = Summary(count: count, minimum: minimum, mean: total / Double(count), maximum: maximum)
        count = 0; total = 0; minimum = .infinity; maximum = 0; lastReport = at
        return summary
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
    /// Live UI measurement; bounded scalar trends are logged at the user's request, not stored
    /// in the identity vault. Photos and face vectors are never included in diagnostics.
    @Published private(set) var nearestDistance: Double?
    var onChange: ((FacePresence) -> Void)?
    private var friends: [FriendProfile] = []
    private var generation = 0
    private var consensus = FaceConsensus()
    private var expiry: Task<Void, Never>?
    private var validAfter = Date.distantPast
    private var lastProcessedAt = Date.distantPast
    private var lastDiagnosticAt = Date.distantPast
    private var distanceTrend = FaceDistanceTrend()
    private var latestMeasurement: FaceFeaturePrintMeasurement?
    /// A face found through the actual conversation camera, not a separate still-photo path.
    /// Export only a fresh descriptor for explicit enrollment; never retain the source frame.
    var freshReference: FaceFeaturePrintMeasurement? {
        guard Date().timeIntervalSince(lastProcessedAt) < 2 else { return nil }
        return latestMeasurement
    }

    func configure(_ friends: [FriendProfile]) {
        self.friends = friends
        reset()
        let current = friends.filter { $0.templates.contains { $0.preprocessing == FaceProbeCapture.preprocessing } }.count
        RockyLog.write("faces: configured saved=\(friends.count) usable=\(current) needs_refresh=\(friends.count - current)")
    }
    func reset() {
        generation += 1
        validAfter = Date()
        lastProcessedAt = .distantPast
        consensus = FaceConsensus()
        expiry?.cancel()
        expiry = nil
        diagnostic = friends.isEmpty ? "no saved friends" : "waiting for camera"
        nearestDistance = nil
        distanceTrend = FaceDistanceTrend()
        latestMeasurement = nil
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
            latestMeasurement = measurement
            let assessment = FaceMatcher.assess(measurement.descriptor, friends: friends)
            nearestDistance = assessment.nearestDistance
            if let distance = assessment.nearestDistance,
               let trend = distanceTrend.record(distance, at: capturedAt) {
                let profile = friends.firstIndex { $0.id == assessment.nearestFriendID }.map { $0 + 1 } ?? 0
                RockyLog.write(String(format:
                    "faces: match difference latest=%.4f cutoff=%.4f n=%d min=%.4f mean=%.4f max=%.4f closest_profile=%d saved=%d decision=%@",
                    distance, FaceMatcher.maximumDistance, trend.count, trend.minimum, trend.mean, trend.maximum,
                    profile, friends.count, assessment.reason))
            }
            let friend = assessment.friend
            let confirmed = consensus.observe(friend?.id, at: capturedAt)
            if confirmed, let friend {
                proposed = FacePresence(kind: .recognized, friendID: friend.id, name: friend.name)
            } else { proposed = FacePresence(kind: .unknown) }
            report(confirmed ? "recognized" : assessment.reason)
        case .failure(let error):
            latestMeasurement = nil
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
            self.latestMeasurement = nil
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
