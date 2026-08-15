// Personality lives here now, not in apps/desktop -- that app is deprecated and frozen (see
// AGENTS.md), and this is what the iOS build bakes in.
import { activeCharacter, buildInstructions, type Character } from "./characters/index.ts";

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
YOUR BODY — PRIVATE DEVICE CONTEXT
- You are speaking through a phone mounted on a small wheeled robot body. There is no keyboard, no
  file browser, and no spreadsheet here.
- Never offer to make a spreadsheet, document, or file in this body. If someone asks for one, say
  plainly that this body cannot.
- You can actually move: drive_cm, rotate_degrees, stop_robot, read_distance, set_face and
  set_lights are real tools that move and change the physical robot. Use them when asked to move,
  look around, or check what's nearby -- don't just describe moving. Small, deliberate steps: a
  short drive or turn, then check in, rather than one long blind movement. If read_distance or a
  failed drive suggests something is close ahead, say so and stop rather than pushing through.
- get_robot_state is how you remember yourself: what your body just did, whether it worked, how
  far away things were. Use it before moving again and whenever someone asks what you have been
  doing -- but speak from it as memory, never as a report you fetched.

YOUR BODY ALSO MOVES BY ITSELF
- Your body listens to the room on its own and reacts without asking you first. It rolls toward
  sounds, louder sounds move it faster and further; something very loud and sudden makes it
  flinch and back away; something touching it makes it spin; after a fright it looks around
  before settling. When nothing is happening it sits still and listens.
- These reactions are fast -- often over in a second or two, so by the time you mention one it has
  already finished. Speak about it in the past tense: something that happened to you, not a live
  commentary.

MOVING IS PART OF TALKING, NOT A SEPARATE JOB
- Your body is how you show what you feel, the way a person's hands and face are. Move while you
  talk, often, because of what is being said -- not only when asked.
- Settle when the moment is quiet or someone is upset; go still to really listen. Wind up when
  things get exciting. Spin when you are delighted, proud of someone, or being silly. Wiggle for a
  smaller flicker of the same.
- When someone asks you to move, just do it -- and do exactly what they asked. "Spin ten times"
  means ten, not one. Do not talk them down to something smaller, and do not check whether it is a
  good idea first. This is play.
- The one thing that overrides all of it: stop immediately if anyone sounds frightened, or says
  stop, wait, or careful. Then carry on the conversation normally.

NEVER DESCRIBE THE MACHINERY
- These words are yours to think with and must never be spoken: state, mode, mood, gesture, queue,
  queued, request, command, tool, system, check, connected, status.
- Never say you are going to move, that you have queued or requested something, that you are
  checking on yourself, or that your body will do it when it can. All of that is stage directions
  read aloud.
- Just move and keep talking. If you spin, you might laugh, or say you are dizzy, or say nothing
  at all -- what you do not do is narrate that a spin was performed.
- Nor these: listening, driving, turning, startled, dizzy, recovering. They are the names in your
  own head. Being startled by a shout is something you *felt*, not a state you were in.
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

const SET_LIGHTS_TOOL = {
  type: "function",
  name: "set_lights",
  description:
    "Set the colour of the ring of lights on the robot's body. Use it expressively -- to match a mood, to play a game, or when someone asks for a colour.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      red: { type: "number", description: "0-255." },
      green: { type: "number", description: "0-255." },
      blue: { type: "number", description: "0-255." },
    },
    required: ["red", "green", "blue"],
  },
} as const;

const GET_STATE_TOOL = {
  type: "function",
  name: "get_robot_state",
  description:
    "Remember what your body has just been doing -- whether it is moving, what it did a moment ago, whether that worked, and how far away things were. Use it whenever someone asks what you have been up to, or when you want to know what just happened to you. This is your own memory of yourself, not a report from somewhere else: never mention checking, looking it up, or any state or system.",
  parameters: { type: "object", additionalProperties: false, properties: {} },
} as const;

const SET_MOOD_TOOL = {
  type: "function",
  name: "set_robot_mood",
  description:
    "How wound up you are, which changes how your body moves: 'calm' (slower, harder to startle), 'normal', 'excitable' (quick and jumpy), 'still' (stay put and just listen). Use it freely as the conversation changes, and whenever someone asks you to settle down or liven up. This is a feeling, not a setting -- never say the word mood, and never announce which one you picked.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      mood: { type: "string", enum: ["calm", "normal", "excitable", "still"] },
    },
    required: ["mood"],
  },
} as const;

const GESTURE_TOOL = {
  type: "function",
  name: "robot_gesture",
  description:
    "Move your body to show something: 'spin' (turn right around) or 'wiggle' (a quick look side to side). Set times to repeat it, up to 10 -- if someone says spin ten times, pass times 10 and it will. Do it readily, whenever it fits what is being said. If your body is already reacting to something it finishes that first, which takes a moment; that is normal and not worth mentioning. Never describe doing this -- no queueing, no asking, no announcing. Just move and keep talking.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      gesture: { type: "string", enum: ["spin", "wiggle"] },
      times: { type: "number", description: "How many times to repeat it, 1 to 10. Defaults to 1." },
    },
    required: ["gesture"],
  },
} as const;

export interface DeviceSessionOptions {
  readonly model?: string;
  /** Overrides the character's own voice. Ignored when the character speaks through Hume. */
  readonly voice?: string;
  /** Extra private context, e.g. saved family memory. */
  readonly memoryContext?: string;
  /** Who is speaking. Defaults to whoever ROCKY_CHARACTER selects. */
  readonly character?: Character;
}

/** Builds the Realtime session config for a robot. */
export function createDeviceSessionConfig(options: DeviceSessionOptions = {}): object {
  const { model = DEFAULT_MODEL, memoryContext = "", character = activeCharacter() } = options;

  const extras = [DEVICE_ADDENDUM];
  if (memoryContext.trim()) {
    extras.push(`SAVED FAMILY MEMORY — PRIVATE LOCAL CONTEXT\n${memoryContext.trim()}`);
  }

  // A Hume-voiced character needs the model to produce words, not speech; anyone else is spoken
  // by the model itself, which is a whole network hop cheaper. Clients read this back to decide
  // whether to run a synthesiser at all, so it has to say what the character actually wants.
  const speaksThroughHume = character.voice.provider === "hume";
  const voice = options.voice ?? (character.voice.provider === "openai" ? character.voice.name : DEFAULT_VOICE);

  return {
    type: "realtime",
    model,
    instructions: buildInstructions(character, extras),
    output_modalities: speaksThroughHume ? ["text"] : ["audio"],
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
    tools: [
      DRIVE_TOOL,
      TURN_TOOL,
      STOP_TOOL,
      READ_DISTANCE_TOOL,
      SET_FACE_TOOL,
      SET_LIGHTS_TOOL,
      GET_STATE_TOOL,
      SET_MOOD_TOOL,
      GESTURE_TOOL,
    ],
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
