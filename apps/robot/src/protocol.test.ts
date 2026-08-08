import { describe, expect, it } from "vitest";

import {
  boundCommand,
  DRIVE_DISTANCE_MAX_CM,
  parseMessage,
  ProtocolError,
  splitLines,
  TURN_DEGREES_MAX,
} from "./protocol.ts";

describe("boundCommand", () => {
  it("clamps an oversized drive distance to the safe max", () => {
    const bounded = boundCommand({ id: "1", type: "drive", distanceCm: 10_000, speed: 50 });
    expect(bounded).toMatchObject({ distanceCm: DRIVE_DISTANCE_MAX_CM, speed: 50 });
  });

  it("clamps a negative drive distance symmetrically", () => {
    const bounded = boundCommand({ id: "1", type: "drive", distanceCm: -10_000, speed: 50 });
    expect(bounded).toMatchObject({ distanceCm: -DRIVE_DISTANCE_MAX_CM });
  });

  it("clamps an out-of-range speed into 0-100", () => {
    const bounded = boundCommand({ id: "1", type: "drive", distanceCm: 10, speed: 500 });
    expect(bounded).toMatchObject({ speed: 100 });
  });

  it("clamps turn degrees to +/- 360", () => {
    const bounded = boundCommand({ id: "1", type: "turn", degrees: 1000, speed: 50 });
    expect(bounded).toMatchObject({ degrees: TURN_DEGREES_MAX });
  });

  it("clamps light color channels into 0-255", () => {
    const bounded = boundCommand({ id: "1", type: "setLights", r: 999, g: -50, b: 128.7 });
    expect(bounded).toMatchObject({ r: 255, g: 0, b: 129 });
  });

  it("passes stop through unchanged", () => {
    const command = { id: "1", type: "stop" } as const;
    expect(boundCommand(command)).toEqual(command);
  });
});

describe("splitLines", () => {
  it("splits multiple complete lines from one chunk", () => {
    const { lines, rest } = splitLines("", '{"a":1}\n{"b":2}\n');
    expect(lines).toEqual(['{"a":1}', '{"b":2}']);
    expect(rest).toBe("");
  });

  it("carries an incomplete tail into rest", () => {
    const { lines, rest } = splitLines("", '{"a":1}\n{"partial":');
    expect(lines).toEqual(['{"a":1}']);
    expect(rest).toBe('{"partial":');
  });

  it("completes a line split across two chunks", () => {
    const first = splitLines("", '{"partial":');
    const second = splitLines(first.rest, '1}\n');
    expect(second.lines).toEqual(['{"partial":1}']);
    expect(second.rest).toBe("");
  });

  it("ignores blank lines", () => {
    const { lines } = splitLines("", "\n\n{\"a\":1}\n\n");
    expect(lines).toEqual(['{"a":1}']);
  });
});

describe("parseMessage", () => {
  it("parses a well-formed message", () => {
    expect(parseMessage('{"type":"stop","id":"1"}')).toEqual({ type: "stop", id: "1" });
  });

  it("rejects invalid JSON", () => {
    expect(() => parseMessage("not json")).toThrow(ProtocolError);
  });

  it("rejects a message with no type field", () => {
    expect(() => parseMessage('{"id":"1"}')).toThrow(ProtocolError);
  });
});
