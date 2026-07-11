export interface EridianChord {
  frequencies: number[];
  durationSeconds: number;
  emphasis: boolean;
}

// Adapted from Lahiru Maramba's MIT-licensed Eridian synthesizer.
// https://github.com/lahirumaramba/rocky/blob/main/synthesizer/rocky.py
const LEXICON: Record<string, number[] | number[][]> = {
  amaze: [659.25, 830.61, 987.77],
  happy: [783.99, 987.77, 1174.66],
  yes: [523.25, 659.25, 783.99],
  fist: [523.25, 659.25, 783.99],
  bump: [523.25, 659.25, 783.99],
  bad: [220, 233.08, 277.18],
  sad: [293.66, 349.23, 440],
  sleep: [261.63, 311.13, 392],
  danger: [698.46, 740, 783.99],
  no: [349.23, 370, 392],
  question: [440, 466.16],
  grace: [493.88, 622.25, 739.99],
  friend: [440, 554.37, 659.25],
  astrophage: [880, 932.33, 987.77],
  rocky: [
    [349.23, 440, 523.25],
    [440, 554.37, 659.25],
    [523.25, 659.25, 783.99],
    [587.33, 739.99, 880],
    [659.25, 830.61, 987.77],
    [783.99, 987.77, 1174.66],
  ],
};

function stableHash(value: string): number {
  let hash = 0x811c9dc5;
  for (const character of value) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

export function stableUnknownChord(word: string): number[] {
  const hash = stableHash(word.toLowerCase());
  return [
    200 + (hash % 700),
    200 + ((hash >>> 8) % 700),
    200 + ((hash >>> 16) % 700),
  ];
}

export function eridianChordsForToken(token: string): EridianChord[] {
  const word = token.toLowerCase().replace(/[^a-z0-9'-]/g, "");
  const excited = /!/.test(token) || word === "amaze" || word === "danger";
  const question = /\?/.test(token);
  const chords: EridianChord[] = [];
  if (word) {
    const entry = LEXICON[word] ?? stableUnknownChord(word);
    const sequence = Array.isArray(entry[0]) ? entry as number[][] : [entry as number[]];
    for (const frequencies of sequence) {
      chords.push({
        frequencies,
        durationSeconds: sequence.length > 1 ? 0.075 : excited ? 0.13 : 0.17,
        emphasis: excited,
      });
    }
  }
  if (question) {
    chords.push({ frequencies: LEXICON.question as number[], durationSeconds: 0.22, emphasis: true });
  }
  return chords;
}

export function splitStreamingTokens(
  buffer: string,
  delta: string,
  flush = false,
): { complete: string[]; remainder: string } {
  const combined = `${buffer}${delta}`;
  if (flush) return { complete: combined.trim().split(/\s+/).filter(Boolean), remainder: "" };
  const finalWhitespace = Math.max(combined.lastIndexOf(" "), combined.lastIndexOf("\n"), combined.lastIndexOf("\t"));
  if (finalWhitespace < 0) return { complete: [], remainder: combined };
  return {
    complete: combined.slice(0, finalWhitespace).trim().split(/\s+/).filter(Boolean),
    remainder: combined.slice(finalWhitespace + 1),
  };
}
