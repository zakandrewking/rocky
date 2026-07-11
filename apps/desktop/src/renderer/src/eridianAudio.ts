import { eridianChordsForToken, splitStreamingTokens } from "../../shared/eridianVoice";

export class EridianAudio {
  private readonly context = new AudioContext();
  private readonly activeOscillators = new Set<OscillatorNode>();
  private nextStart = 0;
  private transcriptBuffer = "";

  constructor(private readonly volume: number) {}

  async resume(): Promise<void> {
    await this.context.resume();
  }

  pushTranscriptDelta(delta: string): void {
    const split = splitStreamingTokens(this.transcriptBuffer, delta);
    this.transcriptBuffer = split.remainder;
    this.scheduleTokens(split.complete);
  }

  flushTranscript(): void {
    const split = splitStreamingTokens(this.transcriptBuffer, "", true);
    this.transcriptBuffer = "";
    this.scheduleTokens(split.complete);
  }

  stop(): void {
    for (const oscillator of this.activeOscillators) {
      try {
        oscillator.stop();
      } catch {
        // Oscillator may already have ended naturally.
      }
    }
    this.activeOscillators.clear();
    this.transcriptBuffer = "";
    this.nextStart = this.context.currentTime;
  }

  async close(): Promise<void> {
    this.stop();
    await this.context.close();
  }

  private scheduleTokens(tokens: string[]): void {
    let start = Math.max(this.context.currentTime + 0.015, this.nextStart);
    for (const token of tokens) {
      for (const chord of eridianChordsForToken(token)) {
        const end = start + chord.durationSeconds;
        const gain = this.context.createGain();
        const peak = Math.max(0, Math.min(0.18, this.volume * (chord.emphasis ? 1.35 : 1)));
        gain.gain.setValueAtTime(0.0001, start);
        gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, peak), start + 0.018);
        gain.gain.exponentialRampToValueAtTime(0.0001, end);
        gain.connect(this.context.destination);

        for (const [index, frequency] of chord.frequencies.entries()) {
          const oscillator = this.context.createOscillator();
          oscillator.type = "sine";
          oscillator.frequency.setValueAtTime(frequency, start);
          oscillator.detune.setValueAtTime((index - 1) * 2.5, start);
          oscillator.connect(gain);
          oscillator.start(start);
          oscillator.stop(end + 0.01);
          this.activeOscillators.add(oscillator);
          oscillator.addEventListener("ended", () => this.activeOscillators.delete(oscillator), { once: true });
        }
        start = end + 0.018;
      }
    }
    this.nextStart = start;
  }
}
