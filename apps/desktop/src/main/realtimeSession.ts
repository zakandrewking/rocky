import { ROCKY_INSTRUCTIONS, SPREADSHEET_TOOL } from "./prompt";

export function createRealtimeSessionConfig(model: string, voice: string): object {
  return {
    type: "realtime",
    model,
    instructions: ROCKY_INSTRUCTIONS,
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
    tools: [SPREADSHEET_TOOL],
    tool_choice: "auto",
  };
}

