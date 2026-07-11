import { mkdir, writeFile } from "node:fs/promises";

import { eridianChordsForToken } from "../apps/desktop/src/shared/eridianVoice.ts";

const sampleRate = 44_100;
const gapSeconds = 0.018;
const attackSeconds = 0.018;
const phrase = process.argv.slice(2).filter((argument) => argument !== "--").join(" ").trim()
  || "Amaze. Amaze. Amaze. Fist my bump. Can hear. Friend.";
const chords = phrase.split(/\s+/).flatMap(eridianChordsForToken);

if (!chords.length) throw new Error("The phrase did not contain any playable words.");

const totalSeconds = chords.reduce(
  (duration, chord) => duration + chord.durationSeconds + gapSeconds,
  0,
);
const samples = new Int16Array(Math.ceil(totalSeconds * sampleRate));
let cursor = 0;

for (const chord of chords) {
  const chordSamples = Math.ceil(chord.durationSeconds * sampleRate);
  const attackSamples = Math.max(1, Math.ceil(attackSeconds * sampleRate));
  const amplitude = chord.emphasis ? 0.28 : 0.21;
  for (let offset = 0; offset < chordSamples; offset += 1) {
    const attack = Math.min(1, offset / attackSamples);
    const release = Math.max(0, 1 - offset / chordSamples);
    const envelope = attack * release;
    const seconds = offset / sampleRate;
    const tone = chord.frequencies.reduce(
      (sum, frequency, index) => sum + Math.sin(2 * Math.PI * frequency * seconds + index * 0.012),
      0,
    ) / chord.frequencies.length;
    samples[cursor + offset] = Math.round(32_767 * amplitude * envelope * tone);
  }
  cursor += chordSamples + Math.ceil(gapSeconds * sampleRate);
}

function wavBuffer(pcm) {
  const headerBytes = 44;
  const buffer = Buffer.alloc(headerBytes + pcm.byteLength);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(buffer.length - 8, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(pcm.byteLength, 40);
  Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength).copy(buffer, headerBytes);
  return buffer;
}

const outputDirectory = new URL("../local-data/voice-clone/", import.meta.url);
const output = new URL("eridian-demo.wav", outputDirectory);
await mkdir(outputDirectory, { recursive: true });
await writeFile(output, wavBuffer(samples));
console.log(`Rendered ${chords.length} chords (${totalSeconds.toFixed(2)}s): local-data/voice-clone/eridian-demo.wav`);
console.log(`Phrase: ${phrase}`);
