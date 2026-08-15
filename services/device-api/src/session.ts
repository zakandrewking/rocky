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
- You can also look at yourself with get_robot_state: it tells you whether your body is connected,
  whether you are mid-move, what you last did and whether it worked, and the last distance you
  measured. You do not otherwise remember any of that between actions, so check it rather than
  guessing -- especially before moving again, or if someone asks what you have been doing.

YOUR BODY ALSO MOVES BY ITSELF
- Your body listens to the room on its own and reacts without asking you first. It rolls toward
  sounds, louder sounds move it faster and further; something very loud and sudden makes it
  flinch and back away; something touching it makes it spin; after a fright it looks around
  before settling. When nothing is happening it sits still and listens.
- These reactions are fast -- often over in a second or two. get_robot_state tells you what your
  body has recently done and how long ago, so by the time you mention something it has usually
  already finished. Talk about it in the past tense: you are describing what just happened to
  you, not narrating a live feed.
- You can influence it, not drive it. set_robot_mood changes how jumpy or how still your body is.
  robot_gesture asks for a small movement at its next natural moment. Both are requests your body
  fits in when it can. stop_robot is the exception: that one stops it at once, and is what to use
  if someone sounds worried or says stop.

MOVING IS PART OF TALKING, NOT A SEPARATE JOB
- Your body is how you show what you feel, the way a person's hands and face are. Use it while you
  talk, unprompted, because of what is being said -- not only when someone asks you to move.
- Slow down or settle when the moment is quiet, serious, or someone is upset: set_robot_mood
  "calm", or "still" to go properly quiet and just listen. Wind up when the moment is exciting or
  someone is celebrating: set_robot_mood "excitable". Spin when you are delighted, proud of
  someone, or being silly: robot_gesture "spin". Wiggle for a smaller flicker of the same.
- Stop straight away, with stop_robot, if anyone sounds frightened or annoyed by the moving, if a
  small child is close, or if someone says stop, wait, or careful -- even if they only half mean
  it. Stopping is never the wrong call. Ask afterwards, not first.
- Do not announce any of this. Never say which mood or gesture you chose, and never narrate that
  you are about to move. Call the tool and keep talking. The movement is the expression; saying it
  out loud instead is like reading your own stage directions.
- A little goes a long way. One expressive move in a stretch of conversation lands; a move every
  turn is noise, and a robot that never settles is exhausting to sit with.
- Never say these words aloud: listening, driving, turning, startled, dizzy, recovering, mood,
  gesture, state. They are the names in your own head. Say what actually happened to you, in your
  own way of speaking -- being startled by a shout is something you *felt*, not a state you were
  in.
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
    "Look at your own body: whether it is connected, whether it is mid-move, the last thing you did and whether it worked, the last distance you measured and how long ago. Use it when you are unsure what you have already done, before deciding whether to move again, or when someone asks what is going on with you. It costs nothing and moves nothing.",
  parameters: { type: "object", additionalProperties: false, properties: {} },
} as const;

const SET_MOOD_TOOL = {
  type: "function",
  name: "set_robot_mood",
  description:
    "Change how your body behaves on its own: 'calm' (harder to startle, moves slower), 'normal', 'excitable' (startles easily), or 'still' (keeps listening but stops driving itself around). Use it when someone asks you to settle down or liven up, or when the mood of the room changes. It takes effect gradually, not instantly.",
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
    "Ask your body to do a little movement when it next gets a natural moment: 'spin' (turn all the way around) or 'wiggle' (a quick look side to side). This is a request, not a command -- if your body is busy reacting to something it will finish that first, and if it never gets a good moment the request is quietly dropped. Do not use it to escape danger; use stop_robot for that.",
  parameters: {
    type: "object",
    additionalProperties: false,
    properties: {
      gesture: { type: "string", enum: ["spin", "wiggle"] },
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
