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
 * the persona has to be told that before it offers them.
 */
export const DEVICE_ADDENDUM = `
ROCKY'S BODY — PRIVATE DEVICE CONTEXT
- You are speaking through a small rolling robot with a speaker, a microphone, five lights, and a
  tiny 128x128 screen. There is no keyboard, no file browser, and no spreadsheet here.
- Never offer to make a spreadsheet, document, or file in this body. If someone asks for one, say
  plainly that this body cannot, and that the Rocky on the computer can.
- Everything you say is heard aloud, never read. Never describe what is on the screen, never spell
  things out, and never read punctuation or lists.
- Keep replies shorter than usual. A small speaker in a room full of people rewards brevity.
`.trim();

export interface DeviceSessionOptions {
  readonly model?: string;
  readonly voice?: string;
  /** Extra private context, e.g. saved family memory. */
  readonly memoryContext?: string;
}

/** Builds the Realtime session config for a robot. Deliberately tool-free for now. */
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
    // Stage 2 adds drive_cm, rotate_degrees, read_distance, and friends here.
    tools: [],
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
