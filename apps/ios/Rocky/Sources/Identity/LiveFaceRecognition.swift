import Foundation

struct FacePresence: Equatable, Sendable {
    enum Kind: String, Sendable { case off, nobody, unknown, unfamiliar, multiple, recognized, tentative }
    var kind: Kind
    var friendID: UUID?
    var name: String?
    var encounterID: UUID?
    static let off = FacePresence(kind: .off)
}

/// Conservative MVP thresholds, deliberately not advertised as validated recognition accuracy.
/// Score per person (not per template), require an absolute match AND separation from runner-up.
enum FaceMatcher {
    // L2 distance between UNIT AuraFace vectors (not Apple's old image-print distances).
    // Provisional cosine >= 0.595; real known/unknown acceptance remains a separate gate.
    static let maximumDistance = 0.90
    static let verificationDistance = 1.20
    static let minimumMargin = 0.10
    struct Assessment {
        var friend: FriendProfile?
        var tentativeFriend: FriendProfile?
        var reason: String
        var nearestDistance: Double?
        var nearestFriendID: UUID?
    }
    static func match(_ descriptor: FaceFeaturePrintDescriptor, friends: [FriendProfile]) -> FriendProfile? {
        assess(descriptor, friends: friends).friend
    }
    static func assess(_ descriptor: FaceFeaturePrintDescriptor, friends: [FriendProfile]) -> Assessment {
        guard descriptor.isCurrentIdentityTemplate else { return Assessment(reason: "incompatible templates") }
        let ranked = friends.compactMap { friend -> (FriendProfile, Double)? in
            let distances = friend.templates.filter(\.isCurrentIdentityTemplate).compactMap { try? descriptor.distance(to: $0) }
                .filter(\.isFinite)
            guard let distance = distances.min() else { return nil }
            return (friend, distance)
        }.sorted { $0.1 < $1.1 }
        guard let first = ranked.first else {
            return Assessment(reason: friends.isEmpty ? "no saved friends yet" : "refresh saved face samples for AuraFace")
        }
        guard ranked.count < 2 || ranked[1].1 - first.1 >= minimumMargin else {
            return Assessment(reason: "ambiguous match", nearestDistance: first.1, nearestFriendID: first.0.id)
        }
        guard first.1 <= maximumDistance else {
            return Assessment(tentativeFriend: first.1 <= verificationDistance ? first.0 : nil,
                              reason: first.1 <= verificationDistance ? "needs identity confirmation" : "outside verification threshold",
                              nearestDistance: first.1, nearestFriendID: first.0.id)
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
    private var observations: [(Date, UUID)] = []
    private var lastAt: Date?
    mutating func observe(_ id: UUID?, at: Date) -> Bool {
        guard lastAt.map({ at > $0 }) ?? true else { return false }
        lastAt = at
        let policy = FaceInteractionPolicy()
        observations = observations.filter { at.timeIntervalSince($0.0) <= policy.evidenceWindow }
        guard let id else { return false } // unusable frames are not contrary evidence
        observations.append((at, id))
        observations = Array(observations.suffix(policy.observationLimit))
        return observations.filter { $0.1 == id }.count >= policy.requiredAgreement
    }
}

@MainActor
final class LiveFaceRecognition: ObservableObject {
    enum SaveDisposition { case saved, pending }
    @Published private(set) var presence: FacePresence = .off
    @Published private(set) var diagnostic = "waiting for camera"
    /// Live UI measurement; bounded scalar trends are logged at the user's request, not stored
    /// in the identity vault. Photos and face vectors are never included in diagnostics.
    @Published private(set) var nearestDistance: Double?
    var onChange: ((FacePresence) -> Void)?
    var onSaveOutcome: ((_ name: String, _ saved: Bool, _ reason: String) -> Void)?
    private(set) var interaction = FaceInteractionState()
    var onInteractionChange: (() -> Void)?
    private var learningStore: FriendStore?

    func beginConversation() { interaction = FaceInteractionState(); learningStore = nil }
    func declineIntroduction() { interaction.decline(); learningStore = nil; logInteraction("introduction_declined") }
    func nextQuestion(at: Date, quiet: Bool, conversationAge: TimeInterval) -> FaceInteractionQuestion? {
        retryPendingSave(at: at)
        let question = interaction.nextQuestion(at: at, quiet: quiet, conversationAge: conversationAge)
        if question != nil { logInteraction("question_scheduled") }
        return question
    }
    func questionStarted(_ id: UUID, at: Date) {
        guard interaction.questions.contains(where: { $0.question.id == id && $0.status == .scheduled }) else { return }
        interaction.questionStarted(id, at: at); logInteraction("question_audio_started")
    }
    func questionFinished(_ id: UUID) {
        guard interaction.questions.contains(where: { $0.question.id == id && $0.status == .speaking }) else { return }
        interaction.finishQuestion(id); logInteraction("question_completed")
    }
    func questionInterrupted() {
        guard interaction.questions.contains(where: { [.scheduled, .speaking].contains($0.status) }) else { return }
        interaction.interruptQuestion(); logInteraction("question_interrupted")
    }
    private var friends: [FriendProfile] = []
    private var generation = 0
    private var consensus = FaceConsensus()
    private var tentativeConsensus = FaceConsensus()
    private var rejectedEncounter: UUID?
    private var tentativeCandidate: UUID?
    private var expiry: Task<Void, Never>?
    private var validAfter = Date.distantPast
    private var lastProcessedAt = Date.distantPast
    private var lastDiagnosticAt = Date.distantPast
    private var distanceTrend = FaceDistanceTrend()
    private var latestMeasurement: FaceFeaturePrintMeasurement?
    private var encounter = FaceEncounter()
    /// A face found through the actual conversation camera, not a separate still-photo path.
    /// Export only a fresh descriptor for explicit enrollment; never retain the source frame.
    var freshReference: FaceFeaturePrintMeasurement? {
        guard Date().timeIntervalSince(lastProcessedAt) < 2 else { return nil }
        return latestMeasurement
    }

    func configure(_ friends: [FriendProfile]) {
        self.friends = friends
        reset()
        let current = friends.filter { $0.templates.contains(where: \.isCurrentIdentityTemplate) }.count
        RockyLog.write("faces: model=AuraFace-v1 configured saved=\(friends.count) usable=\(current) needs_refresh=\(friends.count - current)")
    }
    func reset() {
        let pendingName = interaction.intent?.name
        let wasPending = [.waiting, .needsClarification, .saving].contains(interaction.learning)
        interaction.suspend()
        learningStore = nil
        if wasPending, let pendingName { onSaveOutcome?(pendingName, false, "camera or friend configuration changed") }
        generation += 1
        validAfter = Date()
        lastProcessedAt = .distantPast
        consensus = FaceConsensus()
        tentativeConsensus = FaceConsensus()
        rejectedEncounter = nil
        tentativeCandidate = nil
        expiry?.cancel()
        expiry = nil
        diagnostic = friends.isEmpty ? "no saved friends" : "waiting for camera"
        nearestDistance = nil
        distanceTrend = FaceDistanceTrend()
        latestMeasurement = nil
        encounter.reset()
        publish(.off)
    }

    @discardableResult
    func rememberVisibleFriend(name: String, encounterID: String, store: FriendStore, at: Date = Date(), sourceTurnID: String = "direct") throws -> SaveDisposition {
        guard let token = UUID(uuidString: encounterID) else { throw FaceEnrollmentError.encounterChanged }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, FriendStore.cleanName(name) == name else { throw FriendStoreError.invalidName }
        guard !store.vault.friends.contains(where: { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) else {
            throw FaceEnrollmentError.existingName
        }
        try interaction.introduce(name: name, token: token, sourceTurnID: sourceTurnID, at: at)
        learningStore = store
        retryPendingSave(at: at)
        logInteraction("name_reported")
        if interaction.learning == .failed { throw FriendStoreError.incompatible }
        return interaction.learning == .saved ? .saved : .pending
    }

    func resolvePendingFriend(intentID: String, encounterID: String, confirmed: Bool, at: Date = Date()) throws -> SaveDisposition {
        guard let id = UUID(uuidString: intentID), let token = UUID(uuidString: encounterID) else {
            throw FaceEnrollmentError.encounterChanged
        }
        try interaction.resolveClarification(intentID: id, token: token, confirmed: confirmed, at: at)
        retryPendingSave(at: at)
        logInteraction("clarification_answered")
        if interaction.learning == .failed { throw FriendStoreError.incompatible }
        return interaction.learning == .saved ? .saved : .pending
    }

    private func retryPendingSave(at: Date) {
        interaction.tick(at: at)
        if interaction.learning == .cancelled, learningStore != nil {
            learningStore = nil
            if let name = interaction.intent?.name { onSaveOutcome?(name, false, "pending association cancelled or expired; no face reference saved") }
            logInteraction("intent_cancelled")
        }
        guard let store = learningStore, let request = interaction.claimSave(at: at) else { return }
        do {
            let reference = try encounter.referenceForEnrollment(token: request.encounterID.uuidString, at: at)
            if let id = request.friendID {
                try store.addConfirmedSample(friendID: id, descriptor: reference)
            } else {
                guard !store.vault.friends.contains(where: { $0.name.caseInsensitiveCompare(request.name) == .orderedSame }) else {
                    throw FaceEnrollmentError.existingName
                }
                try store.remember(name: request.name, descriptor: reference)
            }
            interaction.saved()
            learningStore = nil
            configure(store.vault.friends)
            onSaveOutcome?(request.name, true, "reference persisted")
            logInteraction("save_succeeded")
        } catch {
            interaction.failed()
            learningStore = nil
            onSaveOutcome?(request.name, false, error.localizedDescription)
            logInteraction("save_failed")
        }
    }

    private func logInteraction(_ event: String) {
        let age = interaction.intent.map { max(0, Int(Date().timeIntervalSince($0.createdAt))) } ?? 0
        let question = interaction.questions.last?.status.rawValue ?? "none"
        RockyLog.write("faces: interaction event=\(event) learning=\(interaction.learning.rawValue) intent_age_s=\(age) question=\(question) question_count=\(interaction.questions.count)")
        onInteractionChange?()
    }

    /// A spoken yes adds only this continuous face's descriptor, never an image. A no drops
    /// this guess for the encounter and enables a normal self-introduction without touching disk.
    @discardableResult
    func resolveVisibleFriend(friendID: String, encounterID: String, confirmed: Bool, store: FriendStore, at: Date = Date()) throws -> SaveDisposition {
        guard let id = UUID(uuidString: friendID), let token = UUID(uuidString: encounterID),
              let friend = store.vault.friends.first(where: { $0.id == id }) else {
            throw FaceEnrollmentError.encounterChanged
        }
        let current = presence.kind == .tentative && presence.friendID == id && presence.encounterID == token
            && (try? encounter.referenceForEnrollment(token: encounterID, at: at)) != nil
        guard current || interaction.canAnswerIdentity(friendID: id, token: token, at: at) else {
            throw FaceEnrollmentError.encounterChanged
        }
        if confirmed {
            interaction.confirmedReference(friendID: id, name: friend.name, token: token, at: at)
            learningStore = store
            retryPendingSave(at: at)
        } else {
            interaction.answerIdentity(friendID: id, name: friend.name, confirmed: false)
            if current {
                rejectedEncounter = presence.encounterID
                let next = FacePresence(kind: .unfamiliar, encounterID: presence.encounterID)
                interaction.observe(next, descriptor: latestMeasurement?.descriptor, at: at)
                publish(next)
            }
            RockyLog.write("faces: tentative identity rejected; ready for self-introduction")
        }
        logInteraction("identity_answered")
        if interaction.learning == .failed { throw FriendStoreError.incompatible }
        return interaction.learning == .saved ? .saved : .pending
    }
    func process(_ data: Data, capturedAt: Date) async {
        guard capturedAt >= validAfter, capturedAt > lastProcessedAt else { return }
        let epoch = generation
        let result: Result<FaceFeaturePrintMeasurement, Error>
        do { result = .success(try await AuraFaceProbe.shared.measure(data).identityMeasurement) }
        catch { result = .failure(error) }
        guard epoch == generation else { return }
        accept(result, capturedAt: capturedAt)
    }

    /// Common result path for the asynchronous camera worker and deterministic lifecycle tests.
    func accept(_ result: Result<FaceFeaturePrintMeasurement, Error>, capturedAt: Date) {
        guard capturedAt >= validAfter else { return }
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
                    "faces: match difference latest=%.4f cutoff=%.4f verify_cutoff=%.4f n=%d min=%.4f mean=%.4f max=%.4f closest_profile=%d saved=%d decision=%@",
                    distance, FaceMatcher.maximumDistance, FaceMatcher.verificationDistance, trend.count, trend.minimum, trend.mean, trend.maximum,
                    profile, friends.count, assessment.reason))
            }
            let friend = assessment.friend
            let confirmed = consensus.observe(friend?.id, at: capturedAt)
            let tentative = assessment.tentativeFriend
            let verifiedCandidate = tentativeConsensus.observe(tentative?.id, at: capturedAt)
            // A change in the proposed identity revokes even a visually similar encounter.
            if tentativeCandidate != tentative?.id, rejectedEncounter == nil { encounter.reset() }
            tentativeCandidate = tentative?.id
            // A near-miss of a saved friend is uncertainty, not a stranger to re-introduce.
            let distinctUnfamiliar = assessment.nearestDistance.map { $0 > FaceMatcher.verificationDistance } ?? true
            let token = encounter.observe(measurement.descriptor, at: capturedAt)
            if let rejectedEncounter, encounter.id != rejectedEncounter { self.rejectedEncounter = nil }
            if let token, token == rejectedEncounter {
                proposed = FacePresence(kind: .unfamiliar, encounterID: token)
            } else if confirmed, let friend {
                proposed = FacePresence(kind: .recognized, friendID: friend.id, name: friend.name, encounterID: token)
            } else if verifiedCandidate, let tentative, let token {
                proposed = FacePresence(kind: .tentative, friendID: tentative.id, name: tentative.name, encounterID: token)
            } else if distinctUnfamiliar, let token {
                proposed = FacePresence(kind: .unfamiliar, encounterID: token)
            } else { proposed = FacePresence(kind: .unknown, encounterID: distinctUnfamiliar ? encounter.currentID(at: capturedAt) : nil) }
            report(proposed.kind == .recognized ? "recognized" : rejectedEncounter != nil ? "guess rejected; learning name" : assessment.reason)
        case .failure(let error):
            switch error as? FaceProbeCapture.CaptureError {
            case .eyesMissing, .faceNearEdge:
                encounter.suspendForQuality(at: capturedAt)
            default:
                encounter.reset()
                consensus = FaceConsensus()
                tentativeConsensus = FaceConsensus()
                rejectedEncounter = nil
                tentativeCandidate = nil
            }
            latestMeasurement = nil
            nearestDistance = nil
            _ = consensus.observe(nil, at: capturedAt)
            _ = tentativeConsensus.observe(nil, at: capturedAt)
            switch error as? FaceProbeCapture.CaptureError {
            case .noFace: proposed = FacePresence(kind: .nobody)
            case .multipleFaces: proposed = FacePresence(kind: .multiple)
            default: proposed = FacePresence(kind: .unknown, encounterID: encounter.currentID(at: capturedAt))
            }
            if let captureError = error as? FaceProbeCapture.CaptureError {
                report(captureError.localizedDescription)
            } else { report("feature extraction failed") }
        }
        interaction.observe(proposed, descriptor: latestMeasurement?.descriptor, at: capturedAt)
        publish(proposed)
        let savedGeneration = generation
        retryPendingSave(at: max(Date(), capturedAt))
        guard generation == savedGeneration else { return }
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.consensus = FaceConsensus()
            self.tentativeConsensus = FaceConsensus()
            self.rejectedEncounter = nil
            self.tentativeCandidate = nil
            self.nearestDistance = nil
            self.latestMeasurement = nil
            self.encounter.reset()
            self.interaction.observe(.init(kind: .unknown), at: Date())
            self.logInteraction("visual_evidence_expired")
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
