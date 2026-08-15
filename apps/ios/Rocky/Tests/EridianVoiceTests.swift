import XCTest

@testable import Rocky

/// Mirrors apps/desktop/src/shared/eridianVoice.test.ts -- same spec, same cases. If these drift,
/// the two Rockys chirp differently at the same words, which is exactly the kind of thing nobody
/// notices until they are side by side.
final class EridianVoiceTests: XCTestCase {
    func testUsesTheAuthoredChordForAKnownWord() {
        let chords = EridianVoice.chords(for: "friend")

        XCTAssertEqual(chords.count, 1)
        XCTAssertEqual(chords[0].frequencies, [440, 554.37, 659.25])
        XCTAssertEqual(chords[0].durationSeconds, 0.17)
        XCTAssertFalse(chords[0].emphasis)
    }

    func testRockyIsASixChordSignature() {
        let chords = EridianVoice.chords(for: "Rocky")

        XCTAssertEqual(chords.count, 6)
        // Rising: every chord starts above the one before it.
        let roots = chords.map(\.frequencies[0])
        XCTAssertEqual(roots, roots.sorted())
        XCTAssertTrue(chords.allSatisfy { $0.durationSeconds == 0.075 })
    }

    func testPunctuationIsStrippedForLookupButStillRead() {
        // "amaze" is excited on its own; the "!" would do it too.
        let excited = EridianVoice.chords(for: "amaze!")
        XCTAssertEqual(excited[0].frequencies, [659.25, 830.61, 987.77])
        XCTAssertTrue(excited[0].emphasis)
        XCTAssertEqual(excited[0].durationSeconds, 0.13)

        let plain = EridianVoice.chords(for: "friend!")
        XCTAssertTrue(plain[0].emphasis, "the ! makes an ordinary word excited too")
    }

    func testAQuestionAppendsTheQuestionChord() {
        let chords = EridianVoice.chords(for: "question?")

        XCTAssertEqual(chords.count, 2, "the word itself, then the question chord")
        XCTAssertEqual(chords[1].frequencies, [440, 466.16])
        XCTAssertEqual(chords[1].durationSeconds, 0.22)
        XCTAssertTrue(chords[1].emphasis, "always emphasised, whatever the word was")
    }

    func testABareQuestionMarkIsOnlyTheQuestionChord() {
        XCTAssertEqual(EridianVoice.chords(for: "?").count, 1)
    }

    func testATokenWithNothingPronounceableMakesNoSound() {
        XCTAssertTrue(EridianVoice.chords(for: "—").isEmpty)
    }

    func testUnknownWordsAreStableAndDistinct() {
        let first = EridianVoice.stableUnknownChord("spreadsheet")

        XCTAssertEqual(first, EridianVoice.stableUnknownChord("spreadsheet"), "same word, same sound, always")
        XCTAssertNotEqual(first, EridianVoice.stableUnknownChord("volcano"))
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(first.allSatisfy { $0 >= 200 && $0 < 900 })
    }

    /// The hash is FNV-1a; JavaScript's Math.imul and Swift's &* have to agree bit for bit or
    /// every unknown word would sound different across the two apps.
    func testHashMatchesTheJavaScriptOriginal() {
        XCTAssertEqual(EridianVoice.stableHash(""), 0x811c_9dc5)
        XCTAssertEqual(EridianVoice.stableHash("a"), 0xe40c_292c)
        XCTAssertEqual(EridianVoice.stableHash("hello"), 0x4f9f_2cab)
    }

    func testHoldsBackAPartialWordUntilItsWhitespaceArrives() {
        var split = EridianVoice.splitStreamingTokens(buffer: "", delta: "Rocky he")
        XCTAssertEqual(split.complete, ["Rocky"])
        XCTAssertEqual(split.remainder, "he")

        split = EridianVoice.splitStreamingTokens(buffer: split.remainder, delta: "re. ")
        XCTAssertEqual(split.complete, ["here."])
        XCTAssertEqual(split.remainder, "")
    }

    func testFlushEmitsWhateverIsLeft() {
        let split = EridianVoice.splitStreamingTokens(buffer: "frie", delta: "nd", flush: true)

        XCTAssertEqual(split.complete, ["friend"])
        XCTAssertEqual(split.remainder, "")
    }
}
