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
    static func match(_ descriptor: FaceFeaturePrintDescriptor, friends: [FriendProfile]) -> FriendProfile? {
        let ranked = friends.compactMap { friend -> (FriendProfile, Double)? in
            let distances = friend.templates.compactMap { try? descriptor.distance(to: $0) }
                .filter(\.isFinite)
            guard let distance = distances.min() else { return nil }
            return (friend, distance)
        }.sorted { $0.1 < $1.1 }
        guard let first = ranked.first, first.1 <= maximumDistance,
              ranked.count < 2 || ranked[1].1 - first.1 >= minimumMargin else { return nil }
        return first.0
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
    var onChange: ((FacePresence) -> Void)?
    private var friends: [FriendProfile] = []
    private var generation = 0
    private var consensus = FaceConsensus()
    private var expiry: Task<Void, Never>?
    private var validAfter = Date.distantPast
    private var lastProcessedAt = Date.distantPast

    func configure(_ friends: [FriendProfile]) { self.friends = friends; reset() }
    func reset() {
        generation += 1
        validAfter = Date()
        lastProcessedAt = .distantPast
        consensus = FaceConsensus()
        expiry?.cancel()
        expiry = nil
        publish(.off)
    }
    func process(_ data: Data, capturedAt: Date) async {
        guard !friends.isEmpty, capturedAt >= validAfter, capturedAt > lastProcessedAt else { return }
        let epoch = generation
        let result = await Task.detached(priority: .utility) { () -> Result<FaceFeaturePrintMeasurement, Error> in
            Result { try FaceProbeCapture.measure(data) }
        }.value
        guard epoch == generation, Date().timeIntervalSince(capturedAt) < 2 else { return }
        guard capturedAt > lastProcessedAt else { return }
        lastProcessedAt = capturedAt
        let proposed: FacePresence
        switch result {
        case .success(let measurement):
            let friend = FaceMatcher.match(measurement.descriptor, friends: friends)
            let confirmed = consensus.observe(friend?.id, at: capturedAt)
            if confirmed, let friend {
                proposed = FacePresence(kind: .recognized, friendID: friend.id, name: friend.name)
            } else { proposed = FacePresence(kind: .unknown) }
        case .failure(let error):
            _ = consensus.observe(nil, at: capturedAt)
            switch error as? FaceProbeCapture.CaptureError {
            case .noFace: proposed = FacePresence(kind: .nobody)
            case .multipleFaces: proposed = FacePresence(kind: .multiple)
            default: proposed = FacePresence(kind: .unknown)
            }
        }
        publish(proposed)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.consensus = FaceConsensus()
            self.publish(FacePresence(kind: .unknown))
        }
    }
    private func publish(_ next: FacePresence) {
        guard presence != next else { return }
        presence = next
        RockyLog.write("faces: \(next.kind.rawValue)")
        onChange?(next)
    }
}
