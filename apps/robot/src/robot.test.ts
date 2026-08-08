import { describe, expect, it, vi } from "vitest";

import { DRIVE_DISTANCE_MAX_CM } from "./protocol.ts";
import { Robot, RobotCommandError, RobotTimeoutError } from "./robot.ts";
import { MockTransport } from "./transport.ts";

describe("Robot", () => {
  it("acks a bounded drive command", async () => {
    const transport = new MockTransport();
    transport.respond((command) => ({ type: "ack", id: command.id, ok: true }));
    const robot = new Robot(transport);
    await robot.connect();

    await robot.drive(50, 40);

    expect(transport.sent).toContainEqual({
      id: "1",
      type: "drive",
      distanceCm: 50,
      speed: 40,
    });
    robot.disconnect();
  });

  it("clamps an oversized drive request before it reaches the transport", async () => {
    const transport = new MockTransport();
    transport.respond((command) => ({ type: "ack", id: command.id, ok: true }));
    const robot = new Robot(transport);
    await robot.connect();

    await robot.drive(999_999, 40);

    expect(transport.sent[0]).toMatchObject({ distanceCm: DRIVE_DISTANCE_MAX_CM });
    robot.disconnect();
  });

  it("resolves readDistance with the agent's reported distance", async () => {
    const transport = new MockTransport();
    transport.respond((command) => {
      if (command.type === "readDistance") return { type: "distance", id: command.id, ok: true, cm: 42 };
    });
    const robot = new Robot(transport);
    await robot.connect();

    await expect(robot.readDistance()).resolves.toBe(42);
    robot.disconnect();
  });

  it("rejects a command the agent reports as an error", async () => {
    const transport = new MockTransport();
    transport.respond((command) => ({ type: "error", id: command.id, ok: false, message: "motor stall" }));
    const robot = new Robot(transport);
    await robot.connect();

    await expect(robot.stop()).rejects.toThrow(RobotCommandError);
    robot.disconnect();
  });

  it("times out a command the agent never acknowledges", async () => {
    const transport = new MockTransport();
    // No responder installed: the agent never replies.
    const robot = new Robot(transport, { commandTimeoutMs: 20 });
    await robot.connect();

    await expect(robot.stop()).rejects.toThrow(RobotTimeoutError);
    robot.disconnect();
  });

  it("sends periodic heartbeats while connected", async () => {
    vi.useFakeTimers();
    const transport = new MockTransport();
    const robot = new Robot(transport, { heartbeatIntervalMs: 100 });
    await robot.connect();

    await vi.advanceTimersByTimeAsync(350);

    const heartbeats = transport.sent.filter((message) => message.type === "heartbeat");
    expect(heartbeats.length).toBeGreaterThanOrEqual(3);
    robot.disconnect();
    vi.useRealTimers();
  });

  it("delivers unprompted status beacons to onStatus listeners", async () => {
    const transport = new MockTransport();
    const robot = new Robot(transport);
    await robot.connect();
    const statuses: Array<{ battery: number; connected: boolean }> = [];
    robot.onStatus((status) => statuses.push(status));

    transport.deliver({ type: "status", battery: 87, connected: true });

    expect(statuses).toEqual([{ type: "status", battery: 87, connected: true }]);
    robot.disconnect();
  });

  it("rejects in-flight commands when disconnected", async () => {
    const transport = new MockTransport();
    // No responder: the command never gets an ack before disconnect.
    const robot = new Robot(transport);
    await robot.connect();

    const result = robot.stop();
    robot.disconnect();

    await expect(result).rejects.toThrow(RobotTimeoutError);
  });
});
