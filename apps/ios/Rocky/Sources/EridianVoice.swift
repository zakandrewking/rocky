import Foundation

/// Rocky's Eridian chord language: the pure text -> sound mapping, ported from
/// apps/desktop/src/shared/eridianVoice.ts so both apps chirp the same way at the same words.
/// Deliberately free of any audio framework -- EridianAudio does the playing, this only decides
/// what to play, which is also what makes it testable without a device.
///
/// Adapted from Lahiru Maramba's MIT-licensed Eridian synthesizer (see the desktop original for
/// provenance).
struct EridianChord: Equatable {
    let frequencies: [Double]
    let durationSeconds: Double
    let emphasis: Bool
}

enum EridianVoice {
    /// Never queue more than this far ahead. Without it, a long reply turns into a runaway drone
    /// that outlives the speech it was decorating.
    static let maxUtteranceSeconds = 7.5

    /// Authored chords for words Rocky actually says. Every entry is a sequence so the one
    /// multi-chord word (`rocky`, a rising six-chord signature) needs no special case.
    private static let lexicon: [String: [[Double]]] = [
        "amaze": [[659.25, 830.61, 987.77]],       // E5 G#5 B5
        "happy": [[783.99, 987.77, 1174.66]],      // G5 B5 D6
        "yes": [[523.25, 659.25, 783.99]],         // C5 E5 G5
        "fist": [[523.25, 659.25, 783.99]],
        "bump": [[523.25, 659.25, 783.99]],
        "bad": [[220, 233.08, 277.18]],            // A3 A#3 C#4
        "sad": [[293.66, 349.23, 440]],            // D4 F4 A4
        "sleep": [[261.63, 311.13, 392]],          // C4 D#4 G4
        "danger": [[698.46, 740, 783.99]],         // F5 F#5 G5
        "no": [[349.23, 370, 392]],                // F4 F#4 G4
        "question": [[440, 466.16]],               // A4 A#4 -- two voices, not three
        "grace": [[493.88, 622.25, 739.99]],       // B4 D#5 F#5
        "friend": [[440, 554.37, 659.25]],         // A4 C#5 E5
        "astrophage": [[880, 932.33, 987.77]],     // A5 A#5 B5
        "rocky": [
            [349.23, 440, 523.25],
            [440, 554.37, 659.25],
            [523.25, 659.25, 783.99],
            [587.33, 739.99, 880],
            [659.25, 830.61, 987.77],
            [783.99, 987.77, 1174.66],
        ],
    ]

    private static let questionChord = [440.0, 466.16]

    /// FNV-1a, 32-bit. Words with no authored chord still need to sound the *same* every time
    /// they're said, so the pitch comes from a hash rather than anything random.
    static func stableHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for scalar in value.unicodeScalars {
            hash ^= UInt32(scalar.value)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// Three unrelated tones in 200–899 Hz: unknown words are meant to sound like arbitrary alien
    /// clusters, not music.
    static func stableUnknownChord(_ word: String) -> [Double] {
        let hash = stableHash(word.lowercased())
        return [
            200 + Double(hash % 700),
            200 + Double((hash >> 8) % 700),
            200 + Double((hash >> 16) % 700),
        ]
    }

    static func chords(for token: String) -> [EridianChord] {
        // Punctuation is stripped for the lookup but read from the raw token first, so "amaze!"
        // finds `amaze` and still counts as excited.
        let word = token.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }
        let excited = token.contains("!") || word == "amaze" || word == "danger"
        let question = token.contains("?")

        var chords: [EridianChord] = []
        if !word.isEmpty {
            let sequence = lexicon[word] ?? [stableUnknownChord(word)]
            for frequencies in sequence {
                chords.append(
                    EridianChord(
                        frequencies: frequencies,
                        durationSeconds: sequence.count > 1 ? 0.075 : (excited ? 0.13 : 0.17),
                        emphasis: excited
                    )
                )
            }
        }
        if question {
            // Always emphasised, whether or not the word itself was excited.
            chords.append(EridianChord(frequencies: questionChord, durationSeconds: 0.22, emphasis: true))
        }
        return chords
    }

    /// Splits a streaming transcript into whole words, holding a partial word back until the
    /// whitespace that ends it arrives -- chords are per word, so half a word must not chirp.
    static func splitStreamingTokens(
        buffer: String,
        delta: String,
        flush: Bool = false
    ) -> (complete: [String], remainder: String) {
        let combined = buffer + delta
        if flush {
            return (combined.split(whereSeparator: \.isWhitespace).map(String.init), "")
        }
        guard let lastWhitespace = combined.lastIndex(where: \.isWhitespace) else {
            return ([], combined)
        }
        let head = combined[combined.startIndex..<lastWhitespace]
        let tail = combined[combined.index(after: lastWhitespace)...]
        return (head.split(whereSeparator: \.isWhitespace).map(String.init), String(tail))
    }
}
