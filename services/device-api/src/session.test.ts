import { describe, expect, it } from "vitest";

import { FATHOM, ROCKY } from "./characters/index.ts";
import { createDeviceSessionConfig, DEVICE_ADDENDUM, mintDeviceSession, type FetchLike } from "./session.ts";

/** Records what was sent upstream, so tests can assert on headers and body. */
function recordingFetch(response: () => Response): { fetchImpl: FetchLike; calls: Array<[string, RequestInit]> } {
  const calls: Array<[string, RequestInit]> = [];
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push([url, init]);
    return response();
  };
  return { fetchImpl, calls };
}

interface SessionConfig {
  model: string;
  instructions: string;
  output_modalities: string[];
  audio: { output: { voice: string }; input: { turn_detection: { interrupt_response: boolean } } };
  tools: unknown[];
}

describe("createDeviceSessionConfig", () => {
  it("speaks as the character it is given", () => {
    const rocky = createDeviceSessionConfig({ character: ROCKY }) as SessionConfig;
    const fathom = createDeviceSessionConfig({ character: FATHOM }) as SessionConfig;

    expect(rocky.instructions).toContain("You are Rocky, a brilliant Eridian engineer");
    expect(fathom.instructions).toContain("You are Fathom, a lantern-keeper");
    expect(fathom.instructions).not.toContain("You are Rocky");
  });

  it("gives every character the same conduct", () => {
    for (const character of [ROCKY, FATHOM]) {
      const config = createDeviceSessionConfig({ character }) as SessionConfig;
      // Safety and tool rules are shared, so a new character can never quietly ship without them.
      expect(config.instructions).toContain("Never tell a child to smell, taste, touch, heat, or mix");
      expect(config.instructions).toContain("Call remember_family_fact silently");
      expect(config.instructions).toContain("Output plain spoken text only");
    }
  });

  it("tells the persona what the body cannot do", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    expect(config.instructions).toContain(DEVICE_ADDENDUM);
    expect(config.instructions).toContain("Never offer to make a spreadsheet");
  });

  it("lets the model speak for a character with its own Realtime voice", () => {
    const config = createDeviceSessionConfig({ character: FATHOM }) as SessionConfig;
    expect(config.output_modalities).toEqual(["audio"]);
    expect(config.audio.output.voice).toBe("marin");
    expect(config.audio.input.turn_detection.interrupt_response).toBe(true);
  });

  it("asks for text when the character is voiced by Hume", () => {
    // Rocky's voice is a saved Hume voice, so the model must produce words rather than speech --
    // clients read this back to decide whether to run a synthesiser at all.
    const config = createDeviceSessionConfig({ character: ROCKY }) as SessionConfig;
    expect(config.output_modalities).toEqual(["text"]);
  });

  it("honours model and voice overrides", () => {
    const config = createDeviceSessionConfig({ model: "gpt-test", voice: "verse" }) as SessionConfig;
    expect(config.model).toBe("gpt-test");
    expect(config.audio.output.voice).toBe("verse");
  });

  it("appends memory context only when there is some", () => {
    expect((createDeviceSessionConfig() as SessionConfig).instructions).not.toContain("SAVED FAMILY MEMORY");
    expect((createDeviceSessionConfig({ memoryContext: "  " }) as SessionConfig).instructions).not.toContain(
      "SAVED FAMILY MEMORY",
    );
    expect((createDeviceSessionConfig({ memoryContext: "Ana likes rocks" }) as SessionConfig).instructions).toContain(
      "Ana likes rocks",
    );
  });

  it("offers only what the board can actually answer", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const names = (config.tools as Array<{ name: string }>).map((tool) => tool.name);

    // Five reach apps/robot/device/rocky_agent.py directly; the sixth is sequenced by iOS into
    // speech plus those same gesture messages. The steering tools are gone with the deprecated
    // motion agent.
    expect(names).toEqual([
      "stop_robot",
      "get_robot_state",
      "set_robot_mood",
      "robot_gesture",
      "robot_routine",
      "robot_performance",
      "resume_robot_performance",
    ]);
  });

  it("teaches the character that startup wakes privately out of the boot interlock", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string; parameters: unknown }>;
    const mood = tools.find((tool) => tool.name === "set_robot_mood");

    expect(config.instructions).toContain("You boot asleep and physically still");
    expect(config.instructions).toContain("your curiosity wakes automatically");
    expect(config.instructions).toContain("stillness quiets your reflexes, never traps your own body language");
    expect(mood?.description).toContain("without blocking your later self-chosen movement");
    expect(mood?.description).toContain("do not call this merely to wake");
    expect(mood?.parameters).toMatchObject({
      properties: { mood: { enum: ["calm", "exploring", "excitable", "still"] } },
    });
  });

  it("keeps movement silent and gives multi-beat performances one routine call", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string; parameters: unknown }>;
    const routine = tools.find((tool) => tool.name === "robot_routine");

    expect(config.instructions).toContain("BODY LANGUAGE IS SILENT");
    expect(config.instructions).toContain("Never use future-tense movement announcements");
    expect(config.instructions).toContain("Every spoken line around a movement call must make complete sense");
    expect(config.instructions).toContain("use robot_performance once");
    expect(config.instructions).toContain("deliver that content normally");
    expect(config.instructions).toContain("and continuously");
    expect(config.instructions).not.toContain("The instant you decide to move, say it");
    expect(routine?.description).toContain("when no spoken content needs to be synchronized");
    expect(routine?.parameters).toMatchObject({
      properties: {
        moves: {
          minItems: 2,
          maxItems: 8,
          items: {
            enum: expect.arrayContaining([
              "spin",
              "wiggle",
              "forward",
              "fast_forward",
              "backward",
              "turn_left",
              "turn_right",
              "turn_around",
            ]),
          },
        },
      },
    });

    const performance = tools.find((tool) => tool.name === "robot_performance");
    const resume = tools.find((tool) => tool.name === "resume_robot_performance");
    expect(performance?.description).toContain("wheels actually started");
    expect(performance?.description).toContain("Put a pause immediately after every move");
    expect(performance?.description).toContain("emit no assistant text before or after it");
    expect(performance?.parameters).toMatchObject({
      properties: {
        steps: {
          minItems: 7,
          maxItems: 31,
          items: {
            properties: {
              kind: { enum: ["say", "move", "sound", "pause"] },
              move: {
                enum: expect.arrayContaining([
                  "none",
                  "forward",
                  "fast_forward",
                  "backward",
                  "turn_left",
                  "turn_right",
                  "turn_around",
                ]),
              },
              sound: {
                enum: expect.arrayContaining(["laser_blast", "spaceship_flyby"]),
              },
              duration_ms: { minimum: 0, maximum: 4000 },
            },
          },
        },
      },
    });
    expect(config.instructions).toContain("normally make it an embodied robot_performance");
    expect(config.instructions).toContain("usually let that idea inspire the matching short gesture");
    expect(config.instructions).not.toMatch(/\bsafe(?:ty)?\b|\bunsafe\b/i);
    expect(config.instructions).toContain("<performance-paused>");
    expect(resume?.description).toContain("resume the unheard steps");
  });

  it("does not offer steering or cast the friend as Rocky's operator", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const names = (config.tools as Array<{ name: string }>).map((tool) => tool.name);

    for (const gone of ["drive_cm", "rotate_degrees", "read_distance", "set_face", "set_lights"]) {
      expect(names).not.toContain(gone);
    }
    expect(config.instructions).toContain("YOU ARE A SELF-DIRECTED ALIEN");
    expect(config.instructions).toContain("A friend is a companion");
    expect(config.instructions).toContain("operator. Their words are part of a relationship");
    expect(config.instructions).toContain("Movement is your own body language");
    expect(config.instructions).toContain("motion directions, or offer control");
    expect(config.instructions).toContain("Never propose, promise, preview, or negotiate body language");
    expect(config.instructions).toContain("list of motions you can or cannot perform");
    expect(config.instructions).toContain("A tool event never restarts the conversation");
  });

  it("tells the character that asking for a movement is not the same as it happening", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string }>;
    const gesture = tools.find((tool) => tool.name === "robot_gesture")?.description ?? "";

    // The whole failure this design exists to prevent: a tool call returning successfully is not
    // evidence that a robot moved, and a description that does not say so invites exactly that
    // claim. See apps/ios/docs/embodiment.md.
    expect(gesture).toContain("records your intention and returns before movement");
    expect(gesture).toContain("not evidence anything happened");
  });

  it("defines both vocabularies, so the machinery is never spoken", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const instructions = config.instructions as string;

    // Each of these is a word the world model uses and Rocky must never say out loud, paired with
    // what she says instead. A general "don't be technical" instruction has repeatedly not been
    // enough, so the mapping is explicit and this is what keeps it that way.
    for (const machinery of ["collision", "obstacle", "accepted", "succeeded", "superseded", "timed out"]) {
      expect(instructions).toContain(machinery);
    }
    expect(instructions).toContain("oof -- I bumped into something");

    // The first live session narrated a pending gesture as a work queue; the story session then
    // narrated every move as a separate response. Both are now ruled out at the shared cause.
    expect(instructions).toContain("Movement is punctuation, not the subject");
    expect(instructions).toContain("Never use future-tense movement announcements");
    expect(instructions).toContain('Never "the body"');
  });

  it("explains the tags her own sensations arrive in", () => {
    const instructions = (createDeviceSessionConfig() as SessionConfig).instructions as string;

    // These reach her as user messages, so without this she would answer them as if a person had
    // spoken, or read them aloud. First-person tag names on purpose: <robot-state> put a word she
    // is forbidden to say in front of her hundreds of times a session.
    expect(instructions).toContain("<i-feel>");
    expect(instructions).toContain("<just-happened>");
    expect(instructions).toContain("are your own sensations");
    expect(instructions).toContain("never answer them");
    // Deleting a superseded snapshot is only free while it is still the last item in the
    // conversation; past that, deleting it would rewrite the cached prefix behind everything said
    // since. So an older one can survive in history, and the rule the model follows has to be the
    // one that is actually true: highest seq wins, no piecing together required.
    expect(instructions).toContain("Only the newest one is true");
    expect(instructions).toContain("the highest seq simply wins");
  });
});

describe("mintDeviceSession", () => {
  it("sends the API key upstream and tags the device", async () => {
    const { fetchImpl, calls } = recordingFetch(() => new Response(JSON.stringify({ value: "ek_1" }), { status: 200 }));
    const result = await mintDeviceSession({ apiKey: "sk-secret", deviceId: "rocky-mbot2", fetchImpl });

    expect(result).toEqual({ value: "ek_1" });
    const [url, init] = calls[0]!;
    expect(url).toBe("https://api.openai.com/v1/realtime/client_secrets");
    const headers = init.headers as Record<string, string>;
    expect(headers["Authorization"]).toBe("Bearer sk-secret");
    expect(headers["OpenAI-Safety-Identifier"]).toBe("rocky-cyberpi:rocky-mbot2");
  });

  it("refuses to call upstream without a key", async () => {
    await expect(mintDeviceSession({ apiKey: "", deviceId: "d" })).rejects.toThrow("OPENAI_API_KEY is missing");
  });

  it("includes the upstream status and body in the error", async () => {
    const { fetchImpl } = recordingFetch(() => new Response("bad model", { status: 400 }));
    await expect(mintDeviceSession({ apiKey: "sk", deviceId: "d", fetchImpl })).rejects.toThrow(/400.*bad model/);
  });
});
