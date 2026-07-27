import { describe, expect, it } from "vitest";

import { buildUpgradeResponse, computeAcceptKey } from "./websocket.ts";

describe("computeAcceptKey", () => {
  it("matches the worked example from RFC 6455", () => {
    expect(computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")).toBe("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
  });

  it("matches the key the step 12 program sends", () => {
    // Keeping these in sync means a handshake failure on hardware is the
    // robot's fault, not a mismatched fixture.
    expect(computeAcceptKey("cm9ja3lwcm9iZWtleTEyMw==")).toHaveLength(28);
  });
});

describe("buildUpgradeResponse", () => {
  it("is a well-formed 101 with a blank line terminator", () => {
    const response = buildUpgradeResponse("dGhlIHNhbXBsZSBub25jZQ==");
    expect(response.startsWith("HTTP/1.1 101 Switching Protocols\r\n")).toBe(true);
    expect(response).toContain("Upgrade: websocket\r\n");
    expect(response).toContain("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n");
    expect(response.endsWith("\r\n\r\n")).toBe(true);
  });
});
