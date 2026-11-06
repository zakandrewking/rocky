import Foundation

/// Temporary anonymous continuity, not another identity database. A token names one continuous
/// single-face encounter, never an audio speaker. Any gap, switch, group, or camera reset revokes it.
struct FaceEncounter {
    private(set) var id: UUID?
    private(set) var reference: FaceFeaturePrintDescriptor?
    private var count = 0
    private var lastAt: Date?

    mutating func observe(_ descriptor: FaceFeaturePrintDescriptor?, at: Date) -> UUID? {
        guard lastAt.map({ at > $0 }) ?? true else { return nil }
        guard let descriptor, descriptor.isCurrentIdentityTemplate else { reset(); return nil }
        let same = lastAt.map { at.timeIntervalSince($0) <= 2.5 } == true
            && reference.flatMap { try? descriptor.distance(to: $0) }.map { $0 <= 0.55 } == true
        if same { count += 1 }
        else { id = UUID(); reference = descriptor; count = 1 }
        lastAt = at
        return count >= 3 ? id : nil
    }

    mutating func reset() { id = nil; reference = nil; count = 0; lastAt = nil }

    func referenceForEnrollment(token: String, at: Date) throws -> FaceFeaturePrintDescriptor {
        guard let id, UUID(uuidString: token) == id, count >= 3, let lastAt,
              (0..<2).contains(at.timeIntervalSince(lastAt)), let reference else {
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
