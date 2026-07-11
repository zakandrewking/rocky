import { describe, expect, it } from "vitest";

import { ROCKY_INSTRUCTIONS } from "./prompt";
import { createRealtimeSessionConfig } from "./realtimeSession";

describe("Realtime session configuration", () => {
  it("sends the complete persona prompt and selected voice", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice", "Maya: Loves volcanoes");
    expect(config).toMatchObject({
      type: "realtime",
      model: "voice-model",
      instructions: expect.stringContaining(`${ROCKY_INSTRUCTIONS}\n\nSAVED FAMILY MEMORY`),
      audio: { output: { voice: "test-voice" } },
      tool_choice: "auto",
    });
  });

  it("keeps transcription, semantic turn detection, and spreadsheet tool calling", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice") as {
      audio: object;
      tools: Array<{ name: string }>;
    };
    expect(config).toMatchObject({
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
      },
    });
    expect(config.tools.map((tool) => tool.name)).toContain("create_spreadsheet");
    expect(config.tools.map((tool) => tool.name)).toContain("update_active_spreadsheet");
  });

  it("offers local memory as a callable tool", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice") as {
      tools: Array<{ name: string }>;
    };
    expect(config.tools.map((tool) => tool.name)).toContain("remember_family_fact");
  });

  it("supports text-only output for an external speech provider", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice", "", "text");
    expect(config).toMatchObject({ output_modalities: ["text"] });
  });
});
