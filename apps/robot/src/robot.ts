import {
  boundCommand,
  DEFAULT_SPEED,
  type CommandMessage,
  type FaceState,
  type TelemetryMessage,
} from "./protocol.ts";
import type { Transport } from "./transport.ts";

export interface RobotOptions {
  /** How often to send a heartbeat while connected. The device agent stops the motors and
   *  waits for a fresh one if this goes silent (apps/robot/PLAN.md, Phase 1 responsibilities) —
   *  a dropped Wi-Fi link must not leave the robot driving blind. */
  heartbeatIntervalMs?: number;
  /** How long a command may go unacknowledged before Robot gives up on it. */
  commandTimeoutMs?: number;
}

const DEFAULT_HEARTBEAT_INTERVAL_MS = 500;
const DEFAULT_COMMAND_TIMEOUT_MS = 3000;

export class RobotCommandError extends Error {}
export class RobotTimeoutError extends Error {}

interface PendingRequest {
  resolve: (message: TelemetryMessage) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
}

/**
 * Laptop-side robot API (apps/robot/PLAN.md, Phase 2). This is the only thing an LLM tool call
 * or any other Rocky code should touch — never the transport or protocol modules directly —
 * because every command here is bounded (protocol.ts's boundCommand) before it reaches the wire.
 */
export class Robot {
  private nextId = 0;
  private pending = new Map<string, PendingRequest>();
  private heartbeatTimer: ReturnType<typeof setInterval> | undefined;
  private statusListeners: Array<(status: { battery: number; connected: boolean }) => void> = [];

  constructor(
    private readonly transport: Transport,
    private readonly options: RobotOptions = {},
  ) {
    this.transport.onTelemetry((message) => this.handleTelemetry(message));
  }

  async connect(): Promise<void> {
    await this.transport.connect();
    const intervalMs = this.options.heartbeatIntervalMs ?? DEFAULT_HEARTBEAT_INTERVAL_MS;
    this.heartbeatTimer = setInterval(() => {
      this.transport.send({ id: this.allocateId(), type: "heartbeat" });
    }, intervalMs);
  }

  disconnect(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    for (const [id, request] of this.pending) {
      clearTimeout(request.timeout);
      request.reject(new RobotTimeoutError(`disconnected while "${id}" was in flight`));
    }
    this.pending.clear();
    this.transport.close();
  }

  async drive(distanceCm: number, speed: number = DEFAULT_SPEED): Promise<void> {
    await this.sendCommand({ id: this.allocateId(), type: "drive", distanceCm, speed });
  }

  async turn(degrees: number, speed: number = DEFAULT_SPEED): Promise<void> {
    await this.sendCommand({ id: this.allocateId(), type: "turn", degrees, speed });
  }

  async stop(): Promise<void> {
    await this.sendCommand({ id: this.allocateId(), type: "stop" });
  }

  async setFace(face: FaceState): Promise<void> {
    await this.sendCommand({ id: this.allocateId(), type: "setFace", face });
  }

  async setLights(r: number, g: number, b: number): Promise<void> {
    await this.sendCommand({ id: this.allocateId(), type: "setLights", r, g, b });
  }

  async readDistance(): Promise<number> {
    const reply = await this.sendCommand({ id: this.allocateId(), type: "readDistance" });
    if (reply.type !== "distance") {
      throw new RobotCommandError(`expected a distance reply, got "${reply.type}"`);
    }
    return reply.cm;
  }

  async readLineSensors(): Promise<number[]> {
    const reply = await this.sendCommand({ id: this.allocateId(), type: "readLineSensors" });
    if (reply.type !== "lineSensors") {
      throw new RobotCommandError(`expected a lineSensors reply, got "${reply.type}"`);
    }
    return reply.values;
  }

  /** Unprompted battery/connectivity beacons the agent sends outside the request/response flow. */
  onStatus(listener: (status: { battery: number; connected: boolean }) => void): void {
    this.statusListeners.push(listener);
  }

  private allocateId(): string {
    this.nextId += 1;
    return String(this.nextId);
  }

  private sendCommand(command: CommandMessage): Promise<TelemetryMessage> {
    const bounded = boundCommand(command);
    return new Promise((resolve, reject) => {
      const timeoutMs = this.options.commandTimeoutMs ?? DEFAULT_COMMAND_TIMEOUT_MS;
      const timeout = setTimeout(() => {
        this.pending.delete(bounded.id);
        reject(new RobotTimeoutError(`"${bounded.type}" (${bounded.id}) timed out`));
      }, timeoutMs);
      this.pending.set(bounded.id, { resolve, reject, timeout });
      this.transport.send(bounded);
    });
  }

  private handleTelemetry(message: TelemetryMessage): void {
    if (message.type === "status") {
      for (const listener of this.statusListeners) listener(message);
      return;
    }
    const request = this.pending.get(message.id);
    if (!request) return;
    this.pending.delete(message.id);
    clearTimeout(request.timeout);
    if (message.type === "error") {
      request.reject(new RobotCommandError(message.message));
    } else {
      request.resolve(message);
    }
  }
}
