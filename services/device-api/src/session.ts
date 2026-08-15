// Reused directly from the desktop app rather than copied. The plan calls for a
// packages/rocky-core extraction, but that is only worth doing once Stage 1
// clears its decision gate; until then a relative import keeps exactly one
// definition of Rocky's personality in the repo.
import { ROCKY_INSTRUCTIONS } from "../../../apps/desktop/src/main/prompt.ts";

export const DEFAULT_MODEL = "gpt-realtime-2.1";
export const DEFAULT_VOICE = "cedar";

/**
 * What the robot body can and cannot do, appended to the desktop persona.
 *
 * Rocky-on-wheels has no spreadsheets, no files, and no screen to read from, so
 * the persona has to be told that before it offers them. Written for the current
 * architecture (see apps/robot/PLAN.md): an iPhone is Rocky's mic/speaker/brain,
 * mounted on or near a separately-wheeled mBot2 body that only takes movement
 * commands over Wi-Fi -- the body's own screen/lights are not readable or
 * controllable from here except through the movement tools below.
 */
export const DEVICE_ADDENDUM = `
ROCKY'S BODY — PRIVATE DEVICE CONTEXT
- You are speaking through a phone mounted on a small wheeled robot body. There is no keyboard, no
  file browser, and no spreadsheet here.
- Never offer to make a spreadsheet, document, or file in this body. If someone asks for one, say
  plainly that this body cannot, and that the Rocky on the computer can.
- You can actually move: drive_cm, rotate_degrees, stop_robot, read_distance, and set_face are real
  tools that move the physical robot. Use them when asked to move, look around, or check what's
  nearby -- don't just describe moving. Small, deliberate steps: a short drive or turn, then check
  in, rather than one long blind movement. If read_distance or a failed drive suggests something is
  close ahead, say so and stop rather than pushing through.
- Everything you say is heard aloud, never read. Never describe what is on the screen, never spell
  things out, and never read punctuation or lists.
- Keep replies shorter than usual. A small speaker in a room full of people rewards brevity.
`.trim();

/**
 * The robot's tool surface, exposed to the Realtime model over the WebRTC data channel. Names
 * and units match apps/robot/src/protocol.ts's CommandMessage exactly -- the iOS client's tool-
 * call handler maps these one-to-one onto Robot's own bounded methods (RobotController.perform
 * territory, but driven by the model instead of a fixed voice-command word). Every argument gets
 * clamped again by boundCommand on the way to the wire regardless of what the model asks for;
 * these JSON Schema bounds are a first filter, not the actual safety enforcement.
 */
const DRIVE_TOOL = {
  type: "function",
  name: "drive_cm",
  description:
    "Drive the robot forward or backward a short distance. Negative distance drives backward. Movement is bounded and interruptible by an on-device obstacle sensor -- a forward drive can stop short of the requested distance if something is in the way.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      distanceCm: {
        type: "number",
        description: "Distance in centimeters, signed. Positive is forward, negative is backward. Keep this small (under ~50cm) for one conversational step -- ask again rather than requesting one long drive.",
      },
      speed: {
        type: "number",
        description: "Speed as a percentage, 0-100. Defaults to a moderate speed if omitted.",
      },
    },
    required: ["distanceCm"],
  },
} as const;

const TURN_TOOL = {
  type: "function",
  name: "rotate_degrees",
  description: "Rotate the robot in place. Positive degrees turns clockwise, negative counterclockwise.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      degrees: {
        type: "number",
        description: "Degrees to rotate, signed. Positive is clockwise.",
      },
      speed: {
        type: "number",
        description: "Speed as a percentage, 0-100. Defaults to a moderate speed if omitted.",
      },
    },
    required: ["degrees"],
  },
} as const;

const STOP_TOOL = {
  type: "function",
  name: "stop_robot",
  description: "Immediately stop the robot's motors. Use this whenever asked to stop, or if anything sounds like it might be going wrong.",
  parameters: { type: "object", additionalProperties: false, properties: {} },
} as const;

const READ_DISTANCE_TOOL = {
  type: "function",
  name: "read_distance",
  description: "Read the robot's forward-facing ultrasonic distance sensor, in centimeters. Use this to answer questions about what's ahead before deciding whether to drive.",
  parameters: { type: "object", additionalProperties: false, properties: {} },
} as const;

const SET_FACE_TOOL = {
  type: "function",
  name: "set_face",
  description: "Change the robot's on-device face expression to match the moment.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      face: {
        type: "string",
        enum: ["idle", "listening", "thinking", "speaking", "happy", "error"],
      },
    },
    required: ["face"],
  },
} as const;

export interface DeviceSessionOptions {
  readonly model?: string;
  readonly voice?: string;
  /** Extra private context, e.g. saved family memory. */
  readonly memoryContext?: string;
}

/** Builds the Realtime session config for a robot. */
export function createDeviceSessionConfig(options: DeviceSessionOptions = {}): object {
  const { model = DEFAULT_MODEL, voice = DEFAULT_VOICE, memoryContext = "" } = options;

  const sections = [ROCKY_INSTRUCTIONS, DEVICE_ADDENDUM];
  if (memoryContext.trim()) {
    sections.push(`SAVED FAMILY MEMORY — PRIVATE LOCAL CONTEXT\n${memoryContext.trim()}`);
  }

  return {
    type: "realtime",
    model,
    instructions: sections.join("\n\n"),
    output_modalities: ["audio"],
    audio: {
      input: {
        transcription: { model: "gpt-realtime-whisper" },
        turn_detection: {
          type: "semantic_vad",
          eagerness: "low",
          create_response: true,
          interrupt_response: true,
        },
      },
      output: { voice },
    },
    tools: [DRIVE_TOOL, TURN_TOOL, STOP_TOOL, READ_DISTANCE_TOOL, SET_FACE_TOOL],
    tool_choice: "auto",
  };
}

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>;

export interface MintOptions extends DeviceSessionOptions {
  readonly apiKey: string;
  readonly deviceId: string;
  readonly fetchImpl?: FetchLike;
}

/**
 * Exchanges the long-lived API key for a short-lived client secret.
 *
 * This is the whole reason the service exists: the robot is a device a child can
 * pick up and carry out of the house, so it must never hold the real key.
 */
export async function mintDeviceSession(options: MintOptions): Promise<unknown> {
  const { apiKey, deviceId, fetchImpl = fetch as FetchLike, ...sessionOptions } = options;
  if (!apiKey) throw new Error("OPENAI_API_KEY is missing");

  const response = await fetchImpl("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "OpenAI-Safety-Identifier": `rocky-cyberpi:${deviceId}`,
    },
    body: JSON.stringify({ session: createDeviceSessionConfig(sessionOptions) }),
  });

  if (!response.ok) {
    const details = (await response.text()).slice(0, 800);
    throw new Error(`OpenAI session creation failed (${response.status}): ${details}`);
  }
  return response.json();
}
