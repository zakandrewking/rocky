import XCTest
@testable import Rocky

final class FaceInteractionStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    private func time(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func vector(_ angle: Float = 0) -> FaceFeaturePrintDescriptor {
        var values = [Float](repeating: 0, count: 512)
        values[0] = cos(angle); values[1] = sin(angle)
        return .init(algorithm: AuraFaceProbe.algorithm, revision: 1, values: values, preprocessing: AuraFaceProbe.preprocessing)
    }

    func testMinuteOfFocusOscillationDoesNotReaskAnsweredIdentity() throws {
        var state = FaceInteractionState()
        let friend = UUID(), token = UUID()
        let tentative = FacePresence(kind: .tentative, friendID: friend, name: "Zach", encounterID: token)
        state.observe(tentative, descriptor: vector(), at: time(0))
        let question = try XCTUnwrap(state.nextQuestion(at: time(0), quiet: true, conversationAge: 10))
        state.questionStarted(question.id, at: time(0))
        state.answerIdentity(friendID: friend, name: "Zach", confirmed: true)
        for second in 1...65 {
            let presence = second % 3 == 0 ? FacePresence(kind: .unknown) : tentative
            state.observe(presence, descriptor: second % 3 == 0 ? nil : vector(0.1), at: time(Double(second)))
            XCTAssertNil(state.nextQuestion(at: time(Double(second)), quiet: true, conversationAge: 10 + Double(second)))
        }
        XCTAssertEqual(state.participantName, "Zach")
        state.observe(.init(kind: .unknown), at: time(130))
        XCTAssertTrue(state.context(at: time(130)).contains("visual_support_stale"))
        XCTAssertNil(state.nextQuestion(at: time(130), quiet: true, conversationAge: 140))
        XCTAssertEqual(state.participantName, "Zach")
    }

    func testExpiredTrackStillRecordsNameButRequiresFreshExplicitClarification() throws {
        var state = FaceInteractionState()
        let original = UUID(), fresh = UUID()
        state.observe(.init(kind: .unknown, encounterID: original), descriptor: vector(), at: time(0))
        state.observe(.init(kind: .unknown), at: time(3))
        try state.introduce(name: "Julian", token: original, sourceTurnID: "turn-1", at: time(4))
        XCTAssertEqual(state.learning, .needsClarification)
        XCTAssertEqual(state.intent?.sourceTurnID, "turn-1")
        state.observe(.init(kind: .unfamiliar, encounterID: fresh), descriptor: vector(2), at: time(10))
        XCTAssertNil(state.claimSave(at: time(10)))
        let question = try XCTUnwrap(state.nextQuestion(at: time(10), quiet: true, conversationAge: 20))
        XCTAssertEqual(question.kind, .clarification)
        XCTAssertEqual(question.name, "Julian")
        let intent = try XCTUnwrap(question.intentID)
        XCTAssertThrowsError(try state.resolveClarification(intentID: intent, token: fresh, confirmed: true, at: time(10)))
        state.questionStarted(question.id, at: time(10))
        try state.resolveClarification(intentID: intent, token: fresh, confirmed: true, at: time(10))
        XCTAssertEqual(state.claimSave(at: time(10))?.encounterID, fresh)
        state.saved()
        XCTAssertNil(state.claimSave(at: time(10)))
        XCTAssertEqual(state.participantName, "Julian")
    }

    func testScheduledButUnheardQuestionCanRecoverAfterBargeIn() throws {
        var state = FaceInteractionState()
        state.observe(.init(kind: .unfamiliar, encounterID: UUID()), at: time(0))
        let first = try XCTUnwrap(state.nextQuestion(at: time(0), quiet: true, conversationAge: 10))
        XCTAssertNil(state.nextQuestion(at: time(0), quiet: true, conversationAge: 10))
        state.interruptQuestion()
        let retry = try XCTUnwrap(state.nextQuestion(at: time(0.5), quiet: true, conversationAge: 10.5))
        XCTAssertNotEqual(first.id, retry.id)
        state.questionStarted(retry.id, at: time(0.5))
        state.interruptQuestion()
        for second in 1...60 {
            state.observe(.init(kind: .unfamiliar, encounterID: UUID()), at: time(Double(second)))
            XCTAssertNil(state.nextQuestion(at: time(Double(second)), quiet: true, conversationAge: 70))
        }
    }

    func testUnansweredCooldownDoesNotTriggerFromTimerOrInterruptSpeech() throws {
        var state = FaceInteractionState()
        let face = FacePresence(kind: .unfamiliar, encounterID: UUID())
        state.observe(face, at: time(0))
        let question = try XCTUnwrap(state.nextQuestion(at: time(0), quiet: true, conversationAge: 10))
        state.questionStarted(question.id, at: time(0)); state.finishQuestion(question.id)
        state.tick(at: time(121))
        XCTAssertNil(state.nextQuestion(at: time(121), quiet: true, conversationAge: 131))
        state.observe(face, at: time(122))
        XCTAssertNil(state.nextQuestion(at: time(122), quiet: false, conversationAge: 132))
        XCTAssertNotNil(state.nextQuestion(at: time(122), quiet: true, conversationAge: 132))
    }

    func testGroupsAndChangedFaceCannotInheritPendingName() throws {
        var state = FaceInteractionState()
        let first = UUID(), second = UUID(), third = UUID()
        state.observe(.init(kind: .unknown, encounterID: first), descriptor: vector(), at: time(0))
        try state.introduce(name: "Julian", token: first, sourceTurnID: "turn-1", at: time(0))
        state.observe(.init(kind: .multiple), at: time(1))
        XCTAssertNil(state.claimSave(at: time(1)))
        state.observe(.init(kind: .unfamiliar, encounterID: second), descriptor: vector(2), at: time(4))
        let q = try XCTUnwrap(state.nextQuestion(at: time(4), quiet: true, conversationAge: 12))
        state.questionStarted(q.id, at: time(4))
        state.observe(.init(kind: .unfamiliar, encounterID: third), descriptor: vector(2.5), at: time(5))
        XCTAssertThrowsError(try state.resolveClarification(intentID: try XCTUnwrap(q.intentID), token: second, confirmed: true, at: time(5)))
        XCTAssertThrowsError(try state.resolveClarification(intentID: try XCTUnwrap(q.intentID), token: third, confirmed: true, at: time(5)))
        XCTAssertNil(state.claimSave(at: time(5)))
        XCTAssertNil(state.nextQuestion(at: time(5), quiet: true, conversationAge: 15))
    }

    func testIntentExpiryAndPauseKeepConversationNameButNeverWrite() throws {
        for pause in [false, true] {
            var state = FaceInteractionState()
            let token = UUID()
            state.observe(.init(kind: .unknown, encounterID: token), at: time(0))
            try state.introduce(name: "Julian", token: token, sourceTurnID: "turn-1", at: time(0))
            if pause { state.suspend() } else { state.tick(at: time(61)) }
            XCTAssertEqual(state.learning, .cancelled)
            XCTAssertEqual(state.participantName, "Julian")
            state.observe(.init(kind: .unfamiliar, encounterID: token), at: time(62))
            XCTAssertNil(state.claimSave(at: time(62)))
            XCTAssertNil(state.nextQuestion(at: time(62), quiet: true, conversationAge: 72))
        }
    }

    func testDeclineSuppressesFutureQuestionsAndNoStoreFailureClaimsSuccess() throws {
        var state = FaceInteractionState()
        let token = UUID()
        state.observe(.init(kind: .unfamiliar, encounterID: token), at: time(0))
        _ = state.nextQuestion(at: time(0), quiet: true, conversationAge: 10)
        state.decline()
        state.observe(.init(kind: .unfamiliar, encounterID: token), at: time(180))
        XCTAssertNil(state.nextQuestion(at: time(180), quiet: true, conversationAge: 190))
        try state.introduce(name: "Julian", token: token, sourceTurnID: "later-voluntary-introduction", at: time(180))
        XCTAssertNotNil(state.claimSave(at: time(180)))
        state.failed()
        XCTAssertEqual(state.learning, .failed)
        XCTAssertNil(state.claimSave(at: time(180)))
        XCTAssertEqual(state.participantName, "Julian")
    }

    func testSustainedContradictionNotOneFrameAllowsNewPersonIntroduction() throws {
        var state = FaceInteractionState()
        let token = UUID()
        state.observe(.init(kind: .unfamiliar, encounterID: token), descriptor: vector(), at: time(0))
        try state.introduce(name: "Zach", token: token, sourceTurnID: "turn-1", at: time(0))
        state.observe(.init(kind: .unfamiliar, encounterID: UUID()), descriptor: vector(2), at: time(1))
        XCTAssertEqual(state.participantName, "Zach")
        for second in 2...3 {
            state.observe(.init(kind: .unfamiliar, encounterID: UUID()), descriptor: vector(2), at: time(Double(second)))
        }
        XCTAssertNil(state.participantName)
        // Pending learning still needs its ONE clarification, never an automatic name transfer.
        XCTAssertEqual(state.learning, .needsClarification)
        XCTAssertNil(state.claimSave(at: time(3)))
    }

    func testDelayedIdentityAnswerIsRememberedWithoutRepeatingQuestionOrWritingOldFace() throws {
        var state = FaceInteractionState()
        let friend = UUID(), old = UUID(), fresh = UUID()
        state.observe(.init(kind: .tentative, friendID: friend, name: "Zach", encounterID: old),
                      descriptor: vector(), at: time(0))
        let q = try XCTUnwrap(state.nextQuestion(at: time(0), quiet: true, conversationAge: 10))
        state.questionStarted(q.id, at: time(0)); state.finishQuestion(q.id)
        state.observe(.init(kind: .unknown), at: time(4))
        XCTAssertTrue(state.canAnswerIdentity(friendID: friend, token: old, at: time(5)))
        state.confirmedReference(friendID: friend, name: "Zach", token: old, at: time(5))
        XCTAssertEqual(state.participantName, "Zach")
        XCTAssertNil(state.claimSave(at: time(5)))
        for second in 6...40 {
            state.observe(.init(kind: .tentative, friendID: friend, name: "Zach", encounterID: fresh),
                          descriptor: vector(0.1), at: time(Double(second)))
            XCTAssertNil(state.nextQuestion(at: time(Double(second)), quiet: true, conversationAge: 50))
            XCTAssertNil(state.claimSave(at: time(Double(second))))
        }
        state.observe(.init(kind: .recognized, friendID: friend, name: "Zach", encounterID: fresh),
                      descriptor: vector(), at: time(41))
        let update = try XCTUnwrap(state.claimSave(at: time(41)))
        XCTAssertEqual(update.friendID, friend)
        XCTAssertEqual(update.encounterID, fresh)
    }

    func testDeclineAlsoSuppressesTentativeChecksAndUnknownTokensAreRejected() {
        var state = FaceInteractionState()
        state.decline()
        state.observe(.init(kind: .tentative, friendID: UUID(), name: "Zach", encounterID: UUID()), at: time(0))
        XCTAssertNil(state.nextQuestion(at: time(0), quiet: true, conversationAge: 10))
        XCTAssertThrowsError(try state.introduce(name: "Other", token: UUID(), sourceTurnID: "invented", at: time(0)))
        XCTAssertNil(state.intent)
    }

    func testSupportedSameFaceReacquisitionRecoversIntentAcrossMinuteOfRawTrackChurn() throws {
        var state = FaceInteractionState()
        let token = UUID()
        state.observe(.init(kind: .unknown, encounterID: token), descriptor: vector(), at: time(0))
        try state.introduce(name: "Julian", token: token, sourceTurnID: "turn-1", at: time(0))
        for second in 1...50 {
            state.observe(.init(kind: second % 2 == 0 ? .nobody : .unknown), at: time(Double(second)))
            XCTAssertNil(state.claimSave(at: time(Double(second))))
            XCTAssertNil(state.nextQuestion(at: time(Double(second)), quiet: true, conversationAge: 60))
        }
        let recovered = UUID()
        state.observe(.init(kind: .unfamiliar, encounterID: recovered), descriptor: vector(0.1), at: time(51))
        XCTAssertEqual(state.learning, .waiting)
        XCTAssertNil(state.nextQuestion(at: time(51), quiet: true, conversationAge: 61))
        XCTAssertEqual(state.claimSave(at: time(51))?.encounterID, recovered)
        state.saved()
        XCTAssertNil(state.claimSave(at: time(52)))
    }

    func testAWholeMinuteInTentativeBandIsNotDifferentPersonEvidence() {
        var state = FaceInteractionState()
        let friend = UUID(), token = UUID()
        state.observe(.init(kind: .tentative, friendID: friend, name: "Zach", encounterID: token),
                      descriptor: vector(), at: time(0))
        state.answerIdentity(friendID: friend, name: "Zach", confirmed: true)
        for second in 1...65 {
            state.observe(.init(kind: .tentative, friendID: friend, name: "Zach", encounterID: UUID()),
                          descriptor: vector(1.05), at: time(Double(second)))
            XCTAssertEqual(state.participantName, "Zach")
            XCTAssertNil(state.nextQuestion(at: time(Double(second)), quiet: true, conversationAge: 75))
        }
    }
}
