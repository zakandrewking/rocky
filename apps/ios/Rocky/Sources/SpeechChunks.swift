import Foundation

/// Decides how much of Rocky's streaming text to hand Hume at a time, ported from
/// apps/desktop/src/shared/speechChunks.ts.
///
/// The sizes are tuned, not arbitrary: feeding Hume one short sentence at a time made the voice
/// audibly change character between fragments, so chunks accumulate whole sentences until they
/// are worth speaking as one breath.
enum SpeechChunks {
    static let minChunkLength = 180
    static let maxChunkLength = 340

    /// A sentence end: `.`/`!`/`?`, any closing quotes or brackets, then whitespace or the end.
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?](?:["')\]]+)?(?:\s+|$)"#)

    /// Sentence-end offsets within `text`, as the index just past the punctuation run.
    private static func sentenceBoundaries(in text: String) -> [Int] {
        let range = NSRange(text.startIndex..., in: text)
        return sentenceEnd.matches(in: text, range: range).map { $0.range.location + $0.range.length }
    }

    static func split(
        buffer: String,
        delta: String,
        flush: Bool = false
    ) -> (complete: [String], remainder: String) {
        var pending = buffer + delta
        var complete: [String] = []

        while true {
            if pending.isEmpty { break }
            let boundaries = sentenceBoundaries(in: pending)

            // Prefer the first sentence end at or past the minimum: whole sentences, never a
            // fragment, but not one tiny sentence at a time either.
            if let cut = boundaries.first(where: { $0 >= minChunkLength && $0 <= maxChunkLength })
                ?? boundaries.first(where: { $0 >= minChunkLength }).map({ min($0, maxChunkLength) }) {
                complete.append(String(pending.prefix(cut)).trimmingCharacters(in: .whitespacesAndNewlines))
                pending = String(pending.dropFirst(cut))
                continue
            }

            // No usable sentence end, but the buffer is already too long to hold: break at the
            // last space that leaves a sensible chunk rather than mid-word.
            if pending.count >= maxChunkLength {
                let head = pending.prefix(maxChunkLength)
                if let space = head.lastIndex(of: " "),
                    head.distance(from: head.startIndex, to: space) > 20 {
                    let cut = head.distance(from: head.startIndex, to: space)
                    complete.append(String(pending.prefix(cut)).trimmingCharacters(in: .whitespacesAndNewlines))
                    pending = String(pending.dropFirst(cut + 1))
                    continue
                }
            }
            break
        }

        if flush {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { complete.append(tail) }
            pending = ""
        }

        return (complete.filter { !$0.isEmpty }, pending)
    }
}
