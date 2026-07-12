import { describe, expect, it } from "vitest";

import { ROCKY_INSTRUCTIONS } from "./prompt";
import { createRealtimeSessionConfig } from "./realtimeSession";

describe("Realtime session configuration", () => {
  it("sends the complete persona prompt and selected voice", () => {
    const config = createRealtimeSessionConfig(
      "voice-model",
      "test-voice",
      "Maya: Loves volcanoes",
      "Human: We were fixing a spreadsheet.\nRocky: Can hear.",
      {
        researchContext: "- complete: Cobblemon setup",
        localFileContext: "documents:\n- Cobblemon_on_Java_Mac.docx",
      },
    );
    expect(config).toMatchObject({
      type: "realtime",
      model: "voice-model",
      instructions: expect.stringContaining(`${ROCKY_INSTRUCTIONS}\n\nSAVED FAMILY MEMORY`),
      audio: { output: { voice: "test-voice" } },
      tool_choice: "auto",
    });
    expect((config as { instructions: string }).instructions).toContain("RECENT CONVERSATION CONTINUITY");
    expect((config as { instructions: string }).instructions).toContain("We were fixing a spreadsheet");
    expect((config as { instructions: string }).instructions).toContain("RECENT BACKGROUND RESEARCH STATUS");
    expect((config as { instructions: string }).instructions).toContain("Cobblemon setup");
    expect((config as { instructions: string }).instructions).toContain("RECENT ROCKY FILES");
    expect((config as { instructions: string }).instructions).toContain("Cobblemon_on_Java_Mac.docx");
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
            create_response: false,
            interrupt_response: false,
          },
        },
      },
    });
    expect(config.tools.map((tool) => tool.name)).toContain("create_spreadsheet");
    expect(config.tools.map((tool) => tool.name)).toContain("update_active_spreadsheet");
    expect(config.tools.map((tool) => tool.name)).toContain("inspect_current_spreadsheet");
    expect(config.tools.map((tool) => tool.name)).toContain("edit_current_spreadsheet");
    expect(config.tools.map((tool) => tool.name)).toContain("create_how_to_doc");
    expect(config.tools.map((tool) => tool.name)).toContain("list_rocky_files");
    expect(config.tools.map((tool) => tool.name)).toContain("open_rocky_file");
    expect(config.tools.map((tool) => tool.name)).toContain("start_background_research");
  });

  it("offers local memory as a callable tool", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice") as {
      tools: Array<{ name: string }>;
    };
    expect(config.tools.map((tool) => tool.name)).toContain("remember_family_fact");
  });

  it("supports text-only output for an external speech provider", () => {
    const config = createRealtimeSessionConfig("voice-model", "test-voice", "", "", {}, "text");
    expect(config).toMatchObject({ output_modalities: ["text"] });
  });
});
