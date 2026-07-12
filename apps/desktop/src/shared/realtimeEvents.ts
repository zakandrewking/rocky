// Keep responses free of response-level instructions. Session instructions own the persona.
export const RESPONSE_CREATE_EVENT = { type: "response.create" } as const;
export const RESPONSE_CANCEL_EVENT = { type: "response.cancel" } as const;
