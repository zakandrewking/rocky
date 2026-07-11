import { describe, expect, it } from "vitest";

import { ROCKY_INSTRUCTIONS } from "./prompt";
import { createRealtimeSessionConfig } from "./realtimeSession";

describe("Realtime session configuration", () => {
  it("sends the complete persona prompt and selected voice", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice");
    expect(config).toMatchObject({
      type: "realtime",
      model: "voice-model",
      instructions: ROCKY_INSTRUCTIONS,
      audio: { output: { voice: "test-voice" } },
      tool_choice: "auto",
    });
  });

  it("keeps transcription, semantic turn detection, and spreadsheet tool calling", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice");
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
      tools: [{ name: "create_spreadsheet" }],
    });
  });
});

