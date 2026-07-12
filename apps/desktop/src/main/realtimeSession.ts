import {
  BACKGROUND_RESEARCH_TOOL,
  EDIT_SPREADSHEET_TOOL,
  HOW_TO_DOC_TOOL,
  INSPECT_SPREADSHEET_TOOL,
  LIST_ROCKY_FILES_TOOL,
  MEMORY_TOOL,
  OPEN_ROCKY_FILE_TOOL,
  ROCKY_INSTRUCTIONS,
  SPREADSHEET_TOOL,
  UPDATE_SPREADSHEET_TOOL,
} from "./prompt";

export function createRealtimeSessionConfig(
  model: string,
  voice: string,
  memoryContext = "",
  continuityContext = "",
  context: { researchContext?: string; localFileContext?: string } = {},
  outputModality: "audio" | "text" = "audio",
): object {
  const { researchContext = "", localFileContext = "" } = context;
  const contextSections = [
    memoryContext ? `SAVED FAMILY MEMORY — PRIVATE LOCAL CONTEXT\n${memoryContext}` : "",
    continuityContext
      ? `RECENT CONVERSATION CONTINUITY — PRIVATE LOCAL CONTEXT\n${continuityContext}\nUse this to resume naturally after app restarts. Do not recite it.`
      : "",
    researchContext
      ? `RECENT BACKGROUND RESEARCH STATUS — PRIVATE LOCAL CONTEXT\n${researchContext}\nWhen the person asks whether research finished or whether a file used research, answer from this state directly. Do not restart the same research unless asked for fresh research.`
      : "",
    localFileContext
      ? `RECENT ROCKY FILES — PRIVATE LOCAL CONTEXT\n${localFileContext}\nThese files are saved locally from prior Rocky work. If the person asks for something Rocky already made, refer to this context and reopen or update the relevant file when a tool exists.`
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
      INSPECT_SPREADSHEET_TOOL,
      EDIT_SPREADSHEET_TOOL,
      HOW_TO_DOC_TOOL,
      LIST_ROCKY_FILES_TOOL,
      OPEN_ROCKY_FILE_TOOL,
      MEMORY_TOOL,
      BACKGROUND_RESEARCH_TOOL,
    ],
    tool_choice: "auto",
  };
}
