export function pcm16LeToFloat32(base64: string): Float32Array {
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const samples = new Float32Array(Math.floor(bytes.byteLength / 2));
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = view.getInt16(index * 2, true) / 32_768;
  }
  return samples;
}

export function humeTurnWatchdogMs(text: string): number {
  const words = text.trim().split(/\s+/).filter(Boolean).length;
  return Math.max(4_000, Math.min(12_000, 2_000 + words * 420));
}

export class HumePcmAudio {
  private readonly context = new AudioContext();
  private readonly sources = new Set<AudioBufferSourceNode>();
  private readonly sourceTimers = new Map<AudioBufferSourceNode, number>();
  private nextStart = 0;
  private delayNextChunk = false;

  constructor(
    private readonly onSpeaking: (speaking: boolean) => void,
    private readonly initialDelayMs = 0,
  ) {}

  async resume(): Promise<void> {
    await this.context.resume();
  }

  beginResponse(): void {
    this.delayNextChunk = true;
  }

  msUntilPlaybackEnd(): number {
    return Math.max(0, (this.nextStart - this.context.currentTime) * 1_000);
  }

  push(base64: string, sampleRate: number): void {
    const samples = pcm16LeToFloat32(base64);
    if (!samples.length) return;
    const buffer = this.context.createBuffer(1, samples.length, sampleRate);
    buffer.getChannelData(0).set(samples);
    const source = this.context.createBufferSource();
    source.buffer = buffer;
    source.connect(this.context.destination);
    const extraDelay = this.delayNextChunk ? this.initialDelayMs / 1_000 : 0;
    this.delayNextChunk = false;
    const start = Math.max(this.context.currentTime + 0.012 + extraDelay, this.nextStart);
    this.nextStart = start + buffer.duration;
    this.sources.add(source);
    this.onSpeaking(true);
    const finishSource = (): void => {
      const timer = this.sourceTimers.get(source);
      if (timer !== undefined) window.clearTimeout(timer);
      this.sourceTimers.delete(source);
      this.sources.delete(source);
      if (this.sources.size === 0) this.onSpeaking(false);
    };
    source.addEventListener("ended", () => {
      finishSource();
    }, { once: true });
    source.start(start);
    const finishDelayMs = Math.max(100, (start + buffer.duration - this.context.currentTime) * 1_000 + 750);
    this.sourceTimers.set(source, window.setTimeout(finishSource, finishDelayMs));
  }

  stop(): void {
    for (const timer of this.sourceTimers.values()) window.clearTimeout(timer);
    this.sourceTimers.clear();
    for (const source of this.sources) {
      try {
        source.stop();
      } catch {
        // Source may already have ended.
      }
    }
    this.sources.clear();
    this.nextStart = this.context.currentTime;
    this.delayNextChunk = false;
    this.onSpeaking(false);
  }

  async close(): Promise<void> {
    this.stop();
    await this.context.close();
  }
}
