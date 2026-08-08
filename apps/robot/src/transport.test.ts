import net from "node:net";

import { afterEach, describe, expect, it } from "vitest";

import type { CommandMessage } from "./protocol.ts";
import { TcpTransport } from "./transport.ts";

// Exercises TcpTransport against a real loopback TCP server standing in for the CyberPi agent.
// There is no board in this environment (see apps/robot/PLAN.md), so this is the closest thing
// to an integration test available: it proves the socket/newline-framing code path actually
// works over a real socket, just not against real MicroPython on the other end.

describe("TcpTransport", () => {
  let server: net.Server | undefined;
  let transport: TcpTransport | undefined;

  afterEach(() => {
    transport?.close();
    server?.close();
  });

  function listen(onConnection: (socket: net.Socket) => void): Promise<number> {
    return new Promise((resolve) => {
      server = net.createServer(onConnection);
      server.listen(0, "127.0.0.1", () => {
        const address = server?.address();
        if (address && typeof address === "object") resolve(address.port);
      });
    });
  }

  it("connects and receives a telemetry message sent as a single write", async () => {
    const port = await listen((socket) => {
      socket.write('{"type":"status","battery":90,"connected":true}\n');
    });
    transport = new TcpTransport({ host: "127.0.0.1", port });
    const received: unknown[] = [];
    transport.onTelemetry((message) => received.push(message));

    await transport.connect();
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(received).toEqual([{ type: "status", battery: 90, connected: true }]);
  });

  it("reassembles a telemetry message split across two writes", async () => {
    const port = await listen((socket) => {
      socket.write('{"type":"status","batt');
      setTimeout(() => socket.write('ery":50,"connected":false}\n'), 20);
    });
    transport = new TcpTransport({ host: "127.0.0.1", port });
    const received: unknown[] = [];
    transport.onTelemetry((message) => received.push(message));

    await transport.connect();
    await new Promise((resolve) => setTimeout(resolve, 100));

    expect(received).toEqual([{ type: "status", battery: 50, connected: false }]);
  });

  it("sends a command as a newline-terminated JSON line", async () => {
    const receivedLines: string[] = [];
    const port = await listen((socket) => {
      socket.on("data", (chunk) => receivedLines.push(chunk.toString("utf8")));
    });
    transport = new TcpTransport({ host: "127.0.0.1", port });
    await transport.connect();

    const command: CommandMessage = { id: "1", type: "stop" };
    transport.send(command);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(receivedLines).toEqual(['{"id":"1","type":"stop"}\n']);
  });

  it("rejects connect() when nothing is listening on the port", async () => {
    transport = new TcpTransport({ host: "127.0.0.1", port: 1, connectTimeoutMs: 200 });
    await expect(transport.connect()).rejects.toThrow();
  });
});
