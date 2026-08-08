import net from "node:net";

import { splitLines, type CommandMessage, type TelemetryMessage } from "./protocol.ts";

export type TelemetryListener = (message: TelemetryMessage) => void;

/**
 * What Robot (robot.ts) needs from a connection to the CyberPi agent. Kept minimal and
 * transport-agnostic so tests can swap in MockTransport instead of opening a real socket, and so
 * a future WebSocket/MQTT transport (if the OTA/networking research in PLAN.md turns up a better
 * option than raw TCP) is a drop-in replacement.
 */
export interface Transport {
  connect(): Promise<void>;
  send(message: CommandMessage): void;
  onTelemetry(listener: TelemetryListener): void;
  close(): void;
}

export interface TcpTransportOptions {
  host: string;
  port: number;
  /** Milliseconds to wait for `connect()` to establish the socket. */
  connectTimeoutMs?: number;
}

/**
 * Newline-delimited JSON over a plain TCP socket (see protocol.ts for why not WebSocket/MQTT).
 * Untested against a real CyberPi — there is no board attached in this environment — so keep
 * this thin and easy to eyeball against apps/robot/device/rocky_agent.py's socket handling.
 */
export class TcpTransport implements Transport {
  private socket: net.Socket | undefined;
  private buffered = "";
  private listeners: TelemetryListener[] = [];

  constructor(private readonly options: TcpTransportOptions) {}

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: this.options.host, port: this.options.port });
      const timeout = setTimeout(() => {
        socket.destroy();
        reject(new Error(`timed out connecting to ${this.options.host}:${this.options.port}`));
      }, this.options.connectTimeoutMs ?? 5000);

      socket.once("connect", () => {
        clearTimeout(timeout);
        this.socket = socket;
        resolve();
      });
      socket.once("error", (err) => {
        clearTimeout(timeout);
        reject(err);
      });
      socket.on("data", (chunk) => this.handleChunk(chunk.toString("utf8")));
    });
  }

  private handleChunk(chunk: string): void {
    const { lines, rest } = splitLines(this.buffered, chunk);
    this.buffered = rest;
    for (const line of lines) {
      const message = JSON.parse(line) as TelemetryMessage;
      for (const listener of this.listeners) listener(message);
    }
  }

  send(message: CommandMessage): void {
    if (!this.socket) throw new Error("not connected");
    this.socket.write(JSON.stringify(message) + "\n");
  }

  onTelemetry(listener: TelemetryListener): void {
    this.listeners.push(listener);
  }

  close(): void {
    this.socket?.end();
    this.socket = undefined;
  }
}

/**
 * In-memory transport for exercising Robot (robot.ts) without a network or a physical board.
 * `respond` lets a test play the part of the CyberPi agent: inspect the command that was sent
 * and push back whatever telemetry a real agent would.
 */
export class MockTransport implements Transport {
  public sent: CommandMessage[] = [];
  private listeners: TelemetryListener[] = [];
  private responder: ((command: CommandMessage) => TelemetryMessage | void) | undefined;

  connect(): Promise<void> {
    return Promise.resolve();
  }

  send(message: CommandMessage): void {
    this.sent.push(message);
    const reply = this.responder?.(message);
    if (reply) this.deliver(reply);
  }

  /** Installs the fake agent's response logic. */
  respond(responder: (command: CommandMessage) => TelemetryMessage | void): void {
    this.responder = responder;
  }

  /** Pushes a telemetry message as if the agent had sent it unprompted (e.g. a status beacon). */
  deliver(message: TelemetryMessage): void {
    for (const listener of this.listeners) listener(message);
  }

  onTelemetry(listener: TelemetryListener): void {
    this.listeners.push(listener);
  }

  close(): void {
    // nothing to release
  }
}
