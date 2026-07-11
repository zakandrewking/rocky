import { describe, expect, it } from "vitest";

import { START_GREETING_EVENT } from "./realtimeEvents";

describe("Realtime greeting event", () => {
  it("cannot override the session persona prompt", () => {
    expect(START_GREETING_EVENT).toEqual({ type: "response.create" });
    expect(START_GREETING_EVENT).not.toHaveProperty("response.instructions");
  });
});

