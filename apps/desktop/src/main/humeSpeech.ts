import WebSocket from "ws";

import type { HumeAudioEvent } from "../shared/types";

interface HumeChunk {
  type?: string;
  audio?: string;
  is_last_chunk?: boolean;
}

export class HumeSpeech {
  private socket: WebSocket | null = null;
  private connecting: Promise<WebSocket> | null = null;
  private cancelled = false;

  constructor(
    private readonly apiKey: string,
    private readonly voiceId: string,
    private readonly emit: (event: HumeAudioEvent) => void,
  ) {}

  async speak(text: string): Promise<void> {
    const clean = text.trim();
    if (!clean) return;
    this.cancelled = false;
    const socket = await this.connect();
    if (this.cancelled || socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({
      text: clean,
      voice: { id: this.voiceId },
      flush: true,
    }));
  }

  cancel(): void {
    this.cancelled = true;
    this.connecting = null;
    this.socket?.close();
    this.socket = null;
  }

  private connect(): Promise<WebSocket> {
    if (this.socket?.readyState === WebSocket.OPEN) return Promise.resolve(this.socket);
    if (this.connecting) return this.connecting;

    this.connecting = new Promise<WebSocket>((resolve, reject) => {
      const url = new URL("wss://api.hume.ai/v0/tts/stream/input");
      url.searchParams.set("api_key", this.apiKey);
      url.searchParams.set("no_binary", "true");
      url.searchParams.set("instant_mode", "true");
      url.searchParams.set("strip_headers", "true");
      url.searchParams.set("format_type", "pcm");
      url.searchParams.set("version", "2");
      const socket = new WebSocket(url);

      socket.once("open", () => {
        this.socket = socket;
        this.connecting = null;
        resolve(socket);
      });
      socket.on("message", (raw) => {
        try {
          const chunk = JSON.parse(raw.toString()) as HumeChunk;
          if (chunk.type === "audio" && chunk.audio) {
            this.emit({
              type: "audio",
              audio: chunk.audio,
              sampleRate: 48_000,
              isLastChunk: Boolean(chunk.is_last_chunk),
            });
          }
        } catch {
          // Ignore unknown metadata messages; audio chunks remain usable.
        }
      });
      socket.once("error", (error) => {
        this.connecting = null;
        if (this.socket === socket) this.socket = null;
        this.emit({ type: "error", message: error.message });
        reject(error);
      });
      socket.once("close", () => {
        if (this.socket === socket) this.socket = null;
      });
    });
    return this.connecting;
  }
}
