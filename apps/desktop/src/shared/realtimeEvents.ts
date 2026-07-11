// Keep the first response free of response-level instructions. Session instructions own the persona.
export const START_GREETING_EVENT = { type: "response.create" } as const;

