/**
 * Wire protocol between the laptop-side Robot SDK and the CyberPi's on-device agent.
 *
 * Newline-delimited JSON over a plain TCP socket, not WebSocket/MQTT: stock CyberOS
 * MicroPython's socket support is unconfirmed beyond raw `socket` (see apps/robot/PLAN.md,
 * "Open question: OTA and networking on stock CyberOS"), so the transport assumes the least
 * capable option that still works, and nothing here depends on TLS or a WS handshake.
 */

export const PROTOCOL_VERSION = 1;

export const SPEED_MIN = 0;
export const SPEED_MAX = 100;
export const DEFAULT_SPEED = 50;

export const DRIVE_DISTANCE_MAX_CM = 300;
export const TURN_DEGREES_MAX = 360;

export type FaceState = "idle" | "listening" | "thinking" | "speaking" | "happy" | "error";

export type CommandMessage =
  | { id: string; type: "drive"; distanceCm: number; speed: number }
  | { id: string; type: "turn"; degrees: number; speed: number }
  | { id: string; type: "stop" }
  | { id: string; type: "setFace"; face: FaceState }
  | { id: string; type: "setLights"; r: number; g: number; b: number }
  | { id: string; type: "readDistance" }
  | { id: string; type: "readLineSensors" }
  | { id: string; type: "heartbeat" };

export type TelemetryMessage =
  | { type: "ack"; id: string; ok: true }
  /**
   * A drive or turn has physically begun. Sent as soon as the agent starts the maneuver, where
   * `ack` only ever arrives when it *finishes* — which for a multi-second drive is a long time to
   * have nothing at all to go on. Without this, a client can only assume a movement started;
   * with it, it knows. (See apps/ios/docs/embodiment.md: the difference between an assumed and a
   * confirmed action is the difference between "I think I'm turning" and "I'm turning".)
   */
  | { type: "started"; id: string; ok: true }
  /**
   * A reply to `heartbeat`. Proves the board's interpreter is running the loop, which an open
   * TCP socket does not: this project has already had a board whose port answered SYN with
   * SYN-ACK while the interpreter was hung and nothing was ever serviced (see TODOS.md's
   * board-freeze incident). Deliberately not an `ack` so it never lands on the board's own status
   * display, which heartbeats would otherwise overwrite twice a second.
   */
  | { type: "pong"; id: string; ok: true }
  | { type: "error"; id: string; ok: false; message: string }
  | { type: "distance"; id: string; ok: true; cm: number }
  | { type: "lineSensors"; id: string; ok: true; values: number[] }
  | { type: "status"; battery: number; connected: boolean };

export class ProtocolError extends Error {}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/**
 * Bounds every outgoing command to a safe range before it ever reaches the wire. This is the
 * enforcement point for "Rocky never gets direct low-level motor access" (apps/robot/PLAN.md,
 * Phase 2) — an LLM tool call can request a distance or speed, but never one large enough to
 * be unsafe indoors, and never a raw wheel voltage.
 */
export function boundCommand(command: CommandMessage): CommandMessage {
  switch (command.type) {
    case "drive":
      return {
        ...command,
        distanceCm: clamp(command.distanceCm, -DRIVE_DISTANCE_MAX_CM, DRIVE_DISTANCE_MAX_CM),
        speed: clamp(command.speed, SPEED_MIN, SPEED_MAX),
      };
    case "turn":
      return {
        ...command,
        degrees: clamp(command.degrees, -TURN_DEGREES_MAX, TURN_DEGREES_MAX),
        speed: clamp(command.speed, SPEED_MIN, SPEED_MAX),
      };
    case "setLights":
      return {
        ...command,
        r: clamp(Math.round(command.r), 0, 255),
        g: clamp(Math.round(command.g), 0, 255),
        b: clamp(Math.round(command.b), 0, 255),
      };
    default:
      return command;
  }
}

export function encodeMessage(message: CommandMessage | TelemetryMessage): string {
  return JSON.stringify(message) + "\n";
}

/**
 * Splits a raw byte/string chunk on newlines and parses each complete line, returning the
 * parsed messages plus whatever incomplete tail should be prepended to the next chunk. Written
 * this way (rather than assuming one message per chunk) because TCP gives no message
 * boundaries — a slow link can split one JSON line across chunks, or batch several into one.
 */
export function splitLines(buffered: string, chunk: string): { lines: string[]; rest: string } {
  const combined = buffered + chunk;
  const parts = combined.split("\n");
  const rest = parts.pop() ?? "";
  return { lines: parts.filter((line) => line.length > 0), rest };
}

export function parseMessage(line: string): CommandMessage | TelemetryMessage {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new ProtocolError(`not valid JSON: ${line}`);
  }
  if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) {
    throw new ProtocolError(`missing "type" field: ${line}`);
  }
  return parsed as CommandMessage | TelemetryMessage;
}
