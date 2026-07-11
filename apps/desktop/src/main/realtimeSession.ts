import { MEMORY_TOOL, ROCKY_INSTRUCTIONS, SPREADSHEET_TOOL, UPDATE_SPREADSHEET_TOOL } from "./prompt";

export function createRealtimeSessionConfig(
  model: string,
  voice: string,
  memoryContext = "",
  outputModality: "audio" | "text" = "audio",
): object {
  const memoryInstructions = memoryContext
    ? `${ROCKY_INSTRUCTIONS}\n\nSAVED FAMILY MEMORY — PRIVATE LOCAL CONTEXT\n${memoryContext}`
    : ROCKY_INSTRUCTIONS;
  return {
    type: "realtime",
    model,
    instructions: memoryInstructions,
    output_modalities: [outputModality],
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
    tools: [SPREADSHEET_TOOL, UPDATE_SPREADSHEET_TOOL, MEMORY_TOOL],
    tool_choice: "auto",
  };
}
