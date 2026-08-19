/**
 * A character is *who* the voice is, not *what it can do*.
 *
 * The split is the whole point. Tool behaviour, safety rules, memory handling and output format
 * are identical whoever is speaking, and live in shared.ts. A character owns only personality and
 * phraseology: voice, cadence, humour, signature phrases, and the examples that show what right
 * sounds like. Adding a character should never mean restating what is safe to say to a child.
 */

/** The numeric shape of a character's speech, interpolated into its own persona text. */
export interface CharacterCadence {
  readonly defaultMinWords: number;
  readonly defaultMaxWords: number;
  readonly defaultMaxSentences: number;
  readonly greetingMaxWords: number;
  readonly maxQuestionsPerReply: number;
  /** How many times a word is repeated for extreme emphasis. */
  readonly extremeEmphasisRepeats: number;
}

/**
 * How a character is actually voiced.
 *
 * `openai` uses the Realtime model's own speech: one round trip, noticeably lower latency, and no
 * second service to fail. `hume` puts the model in text-only mode and synthesises separately --
 * which is how Rocky gets a voice that is specifically his, at the cost of a second hop.
 */
export type CharacterVoice =
  | { readonly provider: "openai"; readonly name: string }
  | { readonly provider: "hume" }
  /** Text returned to a client-owned synthesizer such as ElevenLabs. */
  | { readonly provider: "local" };

export interface Character {
  /** Stable id; ROCKY_CHARACTER selects by this. */
  readonly id: string;
  readonly name: string;
  /** One line, for logs and for anyone reading the registry. */
  readonly summary: string;
  readonly voice: CharacterVoice;
  readonly cadence: CharacterCadence;
  /**
   * Personality and phraseology only. No tool instructions and no safety rules -- those are
   * shared, and duplicating them here is how two characters quietly drift apart on things that
   * must never differ.
   */
  readonly persona: string;
}
