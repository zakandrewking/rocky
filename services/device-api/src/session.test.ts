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

  it("ships the robot's movement tools", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const names = (config.tools as Array<{ name: string }>).map((tool) => tool.name);
    expect(names).toEqual([
      "drive_cm",
      "rotate_degrees",
      "stop_robot",
      "read_distance",
      "set_face",
      "set_lights",
      "get_robot_state",
      "set_robot_mood",
      "robot_gesture",
    ]);
  });

  it("tells the character that asking to move is not the same as having moved", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    const tools = config.tools as Array<{ name: string; description: string }>;
    const describe_ = (name: string) => tools.find((tool) => tool.name === name)?.description ?? "";

    // The whole failure this design exists to prevent: a tool call returning successfully is not
    // evidence that a robot moved, and a description that does not say so invites exactly that
    // claim. See apps/ios/docs/embodiment.md.
    for (const name of ["drive_cm", "rotate_degrees"]) {
      expect(describe_(name).toLowerCase()).toContain("on its way");
    }
    expect(describe_("drive_cm")).toContain("does NOT mean you have moved");
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
    expect(instructions).toContain("I've told my body to turn -- it hasn't gone yet.");
  });

  it("explains the tags her own body sense arrives in", () => {
    const instructions = (createDeviceSessionConfig() as SessionConfig).instructions as string;

    // These reach her as user messages, so without this she would answer them as if a person had
    // spoken, or read them aloud.
    expect(instructions).toContain("<robot-state>");
    expect(instructions).toContain("<robot-event>");
    expect(instructions).toContain("are your own body sense");
    expect(instructions).toContain("must never be answered as if they were");
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
