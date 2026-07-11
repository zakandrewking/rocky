export function pcm16LeToFloat32(base64: string): Float32Array {
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const samples = new Float32Array(Math.floor(bytes.byteLength / 2));
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = view.getInt16(index * 2, true) / 32_768;
  }
  return samples;
}

export class HumePcmAudio {
  private readonly context = new AudioContext();
  private readonly sources = new Set<AudioBufferSourceNode>();
  private nextStart = 0;

  constructor(private readonly onSpeaking: (speaking: boolean) => void) {}

  async resume(): Promise<void> {
    await this.context.resume();
  }

  push(base64: string, sampleRate: number): void {
    const samples = pcm16LeToFloat32(base64);
    if (!samples.length) return;
    const buffer = this.context.createBuffer(1, samples.length, sampleRate);
    buffer.getChannelData(0).set(samples);
    const source = this.context.createBufferSource();
    source.buffer = buffer;
    source.connect(this.context.destination);
    const start = Math.max(this.context.currentTime + 0.012, this.nextStart);
    this.nextStart = start + buffer.duration;
    this.sources.add(source);
    this.onSpeaking(true);
    source.addEventListener("ended", () => {
      this.sources.delete(source);
      if (this.sources.size === 0) this.onSpeaking(false);
    }, { once: true });
    source.start(start);
  }

  stop(): void {
    for (const source of this.sources) {
      try {
        source.stop();
      } catch {
        // Source may already have ended.
      }
    }
    this.sources.clear();
    this.nextStart = this.context.currentTime;
    this.onSpeaking(false);
  }

  async close(): Promise<void> {
    this.stop();
    await this.context.close();
  }
}
