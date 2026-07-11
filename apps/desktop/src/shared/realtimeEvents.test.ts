import { describe, expect, it } from "vitest";

import { RESPONSE_CREATE_EVENT } from "./realtimeEvents";

describe("Realtime greeting event", () => {
  it("cannot override the session persona prompt", () => {
    expect(RESPONSE_CREATE_EVENT).toEqual({ type: "response.create" });
    expect(RESPONSE_CREATE_EVENT).not.toHaveProperty("response.instructions");
  });
});
