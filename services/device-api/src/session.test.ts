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

    // These five reach apps/robot/device/rocky_agent.py, the one payload that runs. The steering
    // tools are gone with the deprecated motion agent -- a tool the body cannot honour is worse
    // than a missing one, because the model will use it and then explain that it worked.
    expect(names).toEqual([
      "stop_robot",
      "get_robot_state",
      "set_robot_mood",
      "robot_gesture",
      "robot_routine",
    ]);
  });

  it("teaches the character that the robot boots still and must be woken", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string; parameters: unknown }>;
    const mood = tools.find((tool) => tool.name === "set_robot_mood");

    expect(config.instructions).toContain("It boots asleep and physically still");
    expect(config.instructions).toContain("Wake it by becoming 'exploring'");
    expect(mood?.description).toContain("hard movement lock");
    expect(mood?.description).toContain("Your body boots still");
    expect(mood?.parameters).toMatchObject({
      properties: { mood: { enum: ["calm", "exploring", "excitable", "still"] } },
    });
  });

  it("keeps movement silent and gives multi-beat performances one routine call", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string; parameters: unknown }>;
    const routine = tools.find((tool) => tool.name === "robot_routine");

    expect(config.instructions).toContain("BODY LANGUAGE IS SILENT");
    expect(config.instructions).toContain("No \"I will spin\", \"now a wiggle\"");
    expect(config.instructions).toContain("call robot_routine once with the whole sequence");
    expect(config.instructions).toContain("deliver that content normally");
    expect(config.instructions).toContain("and continuously");
    expect(config.instructions).not.toContain("The instant you decide to move, say it");
    expect(routine?.description).toContain("deliver the requested content in the same response");
    expect(routine?.parameters).toMatchObject({
      properties: {
        moves: { minItems: 2, maxItems: 8, items: { enum: ["spin", "wiggle"] } },
      },
    });
  });

  it("does not offer to drive a body that drives itself", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const names = (config.tools as Array<{ name: string }>).map((tool) => tool.name);

    for (const gone of ["drive_cm", "rotate_degrees", "read_distance", "set_face", "set_lights"]) {
      expect(names).not.toContain(gone);
    }
    expect(config.instructions).toContain("It moves itself");
  });

  it("tells the character that asking for a movement is not the same as it happening", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string }>;
    const gesture = tools.find((tool) => tool.name === "robot_gesture")?.description ?? "";

    // The whole failure this design exists to prevent: a tool call returning successfully is not
    // evidence that a robot moved, and a description that does not say so invites exactly that
    // claim. See apps/ios/docs/embodiment.md.
    expect(gesture).toContain("records an intention and returns before movement");
    expect(gesture).toContain("not evidence that anything happened");
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
    expect(instructions).toContain('No "I will spin", "now a wiggle"');
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
