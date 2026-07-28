import { describe, expect, it } from "vitest";

import { handleVoiceTurn } from "./voiceTurn.ts";
import type { FetchLike } from "./session.ts";

/** Returns a fixed response per call, in order - one per upstream leg. */
function sequencedFetch(responses: Response[]): { fetchImpl: FetchLike; calls: Array<[string, RequestInit]> } {
  const calls: Array<[string, RequestInit]> = [];
  let index = 0;
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push([url, init]);
    const response = responses[index];
    index += 1;
    if (!response) throw new Error(`unexpected extra fetch: ${url}`);
    return response;
  };
  return { fetchImpl, calls };
}

const pcm = Buffer.from(new Int16Array([100, -100, 200, -200]).buffer);

describe("handleVoiceTurn", () => {
  it("chains transcription, chat, and speech in order", async () => {
    const chatBody = JSON.stringify({
      output: [{ content: [{ type: "output_text", text: "Rocky says hi." }] }],
    });
    const ttsAudio = new Uint8Array([1, 2, 3, 4]);
    const { fetchImpl, calls } = sequencedFetch([
      new Response(JSON.stringify({ text: "hello rocky" }), { status: 200 }),
      new Response(chatBody, { status: 200 }),
      new Response(ttsAudio, { status: 200 }),
    ]);

    const result = await handleVoiceTurn({ apiKey: "sk-test", pcm, sampleRate: 16000, fetchImpl });

    expect(result.transcript).toBe("hello rocky");
    expect(result.reply).toBe("Rocky says hi.");
    expect(result.audioPcm).toEqual(Buffer.from(ttsAudio));
    expect(result.audioSampleRate).toBe(24000);

    expect(calls[0]![0]).toBe("https://api.openai.com/v1/audio/transcriptions");
    expect(calls[1]![0]).toBe("https://api.openai.com/v1/responses");
    expect(calls[2]![0]).toBe("https://api.openai.com/v1/audio/speech");
  });

  it("skips the chat call entirely when nothing was heard, but still speaks a fallback", async () => {
    const { fetchImpl, calls } = sequencedFetch([
      new Response(JSON.stringify({ text: "   " }), { status: 200 }),
      new Response(new Uint8Array([9]), { status: 200 }),
    ]);

    const result = await handleVoiceTurn({ apiKey: "sk-test", pcm, sampleRate: 16000, fetchImpl });

    expect(result.transcript).toBe("");
    expect(result.reply).toContain("didn't catch that");
    expect(calls).toHaveLength(2);
    expect(calls[1]![0]).toBe("https://api.openai.com/v1/audio/speech");
  });

  it("surfaces the upstream status and body on transcription failure", async () => {
    const { fetchImpl } = sequencedFetch([new Response("bad audio", { status: 400 })]);
    await expect(handleVoiceTurn({ apiKey: "sk-test", pcm, sampleRate: 16000, fetchImpl })).rejects.toThrow(
      /400.*bad audio/,
    );
  });
});
