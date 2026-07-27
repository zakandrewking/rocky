import { describe, expect, it } from "vitest";

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
  it("carries the desktop persona onto the robot", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    // The one definition of Rocky lives in the desktop app; this asserts we
    // are reusing it rather than drifting a second copy.
    expect(config.instructions).toContain("You are Rocky, a brilliant Eridian engineer");
  });

  it("tells the persona what the body cannot do", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    expect(config.instructions).toContain(DEVICE_ADDENDUM);
    expect(config.instructions).toContain("Never offer to make a spreadsheet");
  });

  it("defaults to speech with barge-in enabled", () => {
    const config = createDeviceSessionConfig() as SessionConfig;
    expect(config.output_modalities).toEqual(["audio"]);
    expect(config.audio.input.turn_detection.interrupt_response).toBe(true);
  });

  it("honours model and voice overrides", () => {
    const config = createDeviceSessionConfig({ model: "gpt-test", voice: "marin" }) as SessionConfig;
    expect(config.model).toBe("gpt-test");
    expect(config.audio.output.voice).toBe("marin");
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

  it("ships no tools until Stage 2 adds robot motion", () => {
    expect((createDeviceSessionConfig() as SessionConfig).tools).toEqual([]);
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
