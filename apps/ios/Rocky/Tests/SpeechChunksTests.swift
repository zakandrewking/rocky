import XCTest

@testable import Rocky

/// Mirrors apps/desktop/src/shared/speechChunks.test.ts. The sizes here are tuned, not arbitrary:
/// feeding a local voice one short sentence at a time changes delivery between fragments, so drift
/// shows up as a worse-sounding Rocky, not an error.
final class SpeechChunksTests: XCTestCase {
    private func sentence(_ length: Int) -> String {
        String(repeating: "word ", count: max(1, length / 5)).trimmingCharacters(in: .whitespaces) + "."
    }

    func testHoldsShortTextBackRatherThanSpeakingFragments() {
        let split = SpeechChunks.split(buffer: "", delta: "Rocky here. Small words.")

        XCTAssertTrue(split.complete.isEmpty, "well under the minimum -- keep accumulating")
        XCTAssertEqual(split.remainder, "Rocky here. Small words.")
    }

    func testEmitsAtASentenceEndOnceItIsWorthSpeaking() {
        let long = sentence(200)
        let split = SpeechChunks.split(buffer: "", delta: long + " And more after.")

        XCTAssertEqual(split.complete.count, 1)
        XCTAssertTrue(split.complete[0].hasSuffix("."))
        XCTAssertGreaterThanOrEqual(split.complete[0].count, 180)
        XCTAssertEqual(split.remainder.trimmingCharacters(in: .whitespaces), "And more after.")
    }

    func testNeverExceedsTheMaximumEvenWithNoSentenceEnd() {
        let runOn = String(repeating: "alpha ", count: 120)  // 720 chars, no punctuation at all
        let split = SpeechChunks.split(buffer: "", delta: runOn)

        XCTAssertFalse(split.complete.isEmpty, "a run-on has to be broken somewhere")
        for chunk in split.complete {
            XCTAssertLessThanOrEqual(chunk.count, 340)
        }
        XCTAssertFalse(split.complete[0].hasSuffix("alph"), "break at a space, not mid-word")
    }

    func testFlushEmitsTheTailHoweverShort() {
        let split = SpeechChunks.split(buffer: "Rocky here.", delta: "", flush: true)

        XCTAssertEqual(split.complete, ["Rocky here."])
        XCTAssertEqual(split.remainder, "")
    }

    func testFlushWithNothingPendingSaysNothing() {
        let split = SpeechChunks.split(buffer: "   ", delta: "", flush: true)

        XCTAssertTrue(split.complete.isEmpty, "whitespace is not an utterance")
        XCTAssertEqual(split.remainder, "")
    }
}
