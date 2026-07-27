import { describe, expect, it, vi } from "vitest";

import { parseDeviceTokens } from "./auth.ts";
import { handleRequest, type RouterDeps } from "./router.ts";

const TOKEN = "0123456789abcdef0123";
const registry = parseDeviceTokens(`rocky-mbot2:${TOKEN}`);
const openRegistry = parseDeviceTokens("");

function request(method: string, path: string, body = "", headers: Record<string, string> = {}) {
  return { method, path, headers, body };
}

function authed(method: string, path: string, body = "") {
  return request(method, path, body, { authorization: `Bearer ${TOKEN}` });
}

const deps: RouterDeps = { registry, now: () => new Date("2026-07-27T12:00:00Z") };

describe("GET /v1/health", () => {
  it("is open and reports the time", async () => {
    const response = await handleRequest(request("GET", "/v1/health"), deps);
    expect(response.status).toBe(200);
    expect(JSON.parse(String(response.body))).toEqual({
      ok: true,
      service: "rocky-device-api",
      time: "2026-07-27T12:00:00.000Z",
    });
  });

  it("ignores a query string", async () => {
    const response = await handleRequest(request("GET", "/v1/health?t=1"), deps);
    expect(response.status).toBe(200);
  });
});

describe("probe endpoints", () => {
  it("echo reports the byte count so the robot can measure uplink", async () => {
    const response = await handleRequest(authed("POST", "/v1/probe/echo", "x".repeat(4096)), deps);
    expect(JSON.parse(String(response.body))).toEqual({ ok: true, bytes: 4096 });
  });

  it("serves a playable WAV", async () => {
    const response = await handleRequest(authed("GET", "/v1/probe/audio.wav"), deps);
    expect(response.status).toBe(200);
    expect(response.headers["Content-Type"]).toBe("audio/wav");
    expect(Buffer.from(response.body).subarray(0, 4).toString("ascii")).toBe("RIFF");
  });

  it("stays open before any device token is configured", async () => {
    const response = await handleRequest(request("POST", "/v1/probe/echo", "hi"), { registry: openRegistry });
    expect(response.status).toBe(200);
  });

  it("locks down once a device token exists", async () => {
    const response = await handleRequest(request("POST", "/v1/probe/echo", "hi"), deps);
    expect(response.status).toBe(401);
  });
});

describe("POST /v1/probe/report", () => {
  const report = {
    probe: "rocky-cyberpi-stage1",
    checks: [{ section: "audio", name: "raw", ok: false, detail: "none" }],
    verdict: { answer: "no" },
  };

  it("accepts and forwards a probe report", async () => {
    const onProbeReport = vi.fn();
    const response = await handleRequest(authed("POST", "/v1/probe/report", JSON.stringify(report)), {
      ...deps,
      onProbeReport,
    });
    expect(response.status).toBe(200);
    expect(JSON.parse(String(response.body))).toEqual({ ok: true, checks: 1 });
    expect(onProbeReport).toHaveBeenCalledWith(report);
  });

  it("rejects malformed JSON", async () => {
    const response = await handleRequest(authed("POST", "/v1/probe/report", "{nope"), deps);
    expect(response.status).toBe(400);
  });

  it("rejects a payload that is not a probe report", async () => {
    const response = await handleRequest(authed("POST", "/v1/probe/report", JSON.stringify({ hello: 1 })), deps);
    expect(response.status).toBe(400);
  });
});

describe("POST /v1/device/session", () => {
  it("requires authentication even when no devices are registered", async () => {
    const response = await handleRequest(request("POST", "/v1/device/session"), {
      registry: openRegistry,
      apiKey: "sk-test",
    });
    expect(response.status).toBe(401);
  });

  it("rejects a wrong token", async () => {
    const response = await handleRequest(request("POST", "/v1/device/session", "", { authorization: "Bearer nope" }), {
      ...deps,
      apiKey: "sk-test",
    });
    expect(response.status).toBe(401);
  });

  it("reports a missing API key rather than failing opaquely", async () => {
    const response = await handleRequest(authed("POST", "/v1/device/session"), deps);
    expect(response.status).toBe(503);
  });

  it("returns the minted client secret and never the API key", async () => {
    const fetchImpl = vi.fn(async () =>
      new Response(JSON.stringify({ value: "ek_ephemeral", expires_at: 123 }), { status: 200 }),
    );
    const response = await handleRequest(authed("POST", "/v1/device/session"), {
      ...deps,
      apiKey: "sk-secret",
      fetchImpl,
    });

    expect(response.status).toBe(200);
    const payload = JSON.parse(String(response.body));
    expect(payload.device_id).toBe("rocky-mbot2");
    expect(payload.session).toEqual({ value: "ek_ephemeral", expires_at: 123 });
    expect(String(response.body)).not.toContain("sk-secret");
  });

  it("surfaces an upstream failure as 502", async () => {
    const fetchImpl = vi.fn(async () => new Response("no quota", { status: 429 }));
    const response = await handleRequest(authed("POST", "/v1/device/session"), {
      ...deps,
      apiKey: "sk-secret",
      fetchImpl,
    });
    expect(response.status).toBe(502);
    expect(String(response.body)).toContain("429");
  });
});

describe("unknown routes", () => {
  it("404s with the route echoed back", async () => {
    const response = await handleRequest(request("GET", "/nope"), deps);
    expect(response.status).toBe(404);
    expect(JSON.parse(String(response.body)).route).toBe("GET /nope");
  });
});
