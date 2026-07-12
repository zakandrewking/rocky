import {
  BACKGROUND_RESEARCH_TOOL,
  EDIT_SPREADSHEET_TOOL,
  HOW_TO_DOC_TOOL,
  MEMORY_TOOL,
  ROCKY_INSTRUCTIONS,
  SPREADSHEET_TOOL,
  UPDATE_SPREADSHEET_TOOL,
} from "./prompt";

export function createRealtimeSessionConfig(
  model: string,
  voice: string,
  memoryContext = "",
  continuityContext = "",
  outputModality: "audio" | "text" = "audio",
): object {
  const contextSections = [
    memoryContext ? `SAVED FAMILY MEMORY — PRIVATE LOCAL CONTEXT\n${memoryContext}` : "",
    continuityContext
      ? `RECENT CONVERSATION CONTINUITY — PRIVATE LOCAL CONTEXT\n${continuityContext}\nUse this to resume naturally after app restarts. Do not recite it.`
      : "",
  ].filter(Boolean);
  const instructions = contextSections.length ? `${ROCKY_INSTRUCTIONS}\n\n${contextSections.join("\n\n")}` : ROCKY_INSTRUCTIONS;
  return {
    type: "realtime",
    model,
    instructions,
    output_modalities: [outputModality],
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
      output: { voice },
    },
    tools: [
      SPREADSHEET_TOOL,
      UPDATE_SPREADSHEET_TOOL,
      EDIT_SPREADSHEET_TOOL,
      HOW_TO_DOC_TOOL,
      MEMORY_TOOL,
      BACKGROUND_RESEARCH_TOOL,
    ],
    tool_choice: "auto",
  };
}
