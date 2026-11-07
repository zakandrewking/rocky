import Foundation

/// Temporary anonymous continuity, not another identity database. A token names one continuous
/// single-face encounter, never an audio speaker. A missing face, switch, group, or camera reset
/// revokes it. One brief quality dip may preserve the token, but never enrollment readiness.
struct FaceEncounter {
    private(set) var id: UUID?
    private(set) var reference: FaceFeaturePrintDescriptor?
    private var count = 0
    private var sampleTimes: [Date] = []
    private var suspended = false
    private var lastAt: Date?

    mutating func observe(_ descriptor: FaceFeaturePrintDescriptor?, at: Date) -> UUID? {
        guard lastAt.map({ at > $0 }) ?? true else { return nil }
        guard let descriptor, descriptor.isCurrentIdentityTemplate else { reset(); return nil }
        let same = lastAt.map { at.timeIntervalSince($0) <= 2.5 } == true
            && reference.flatMap { try? descriptor.distance(to: $0) }.map { $0 <= 0.55 } == true
        if same { sampleTimes.append(at) }
        else { id = UUID(); reference = descriptor; sampleTimes = [at] }
        let policy = FaceInteractionPolicy()
        sampleTimes = Array(sampleTimes.filter { at.timeIntervalSince($0) <= policy.evidenceWindow }.suffix(policy.observationLimit))
        count = sampleTimes.count
        suspended = false
        lastAt = at
        return count >= policy.requiredAgreement ? id : nil
    }

    mutating func reset() { id = nil; reference = nil; count = 0; lastAt = nil; sampleTimes = []; suspended = false }

    func currentID(at: Date) -> UUID? {
        guard let lastAt, (0...2.5).contains(at.timeIntervalSince(lastAt)) else { return nil }
        return id
    }

    mutating func suspendForQuality(at: Date) {
        // Do not advance lastAt: repeated bad frames cannot keep an old encounter alive.
        if currentID(at: at) == nil { reset() }
        else { suspended = true }
    }

    func referenceForEnrollment(token: String, at: Date) throws -> FaceFeaturePrintDescriptor {
        guard !suspended, let id, UUID(uuidString: token) == id, count >= FaceInteractionPolicy().requiredAgreement, let lastAt,
              (0..<FaceInteractionPolicy().enrollmentFreshness).contains(at.timeIntervalSince(lastAt)), let reference else {
            throw FaceEnrollmentError.encounterChanged
        }
        return reference
    }
}

enum FaceEnrollmentError: LocalizedError {
    case encounterChanged, existingName
    var errorDescription: String? {
        switch self {
        case .encounterChanged: "Do not save. The same single unfamiliar face is no longer confidently visible. Keep talking; do not guess who is speaking."
        case .existingName: "That name already belongs to a saved friend. Do not replace or add to their face samples by voice; use Friends for an explicit correction."
        }
    }
}
