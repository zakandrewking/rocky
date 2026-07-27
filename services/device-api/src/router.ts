import { authenticate, type DeviceRegistry } from "./auth.ts";
import { isProbeReport, type ProbeReport } from "./probeReport.ts";
import { mintDeviceSession, type DeviceSessionOptions, type FetchLike } from "./session.ts";
import { generateTone } from "./wav.ts";

export interface DeviceRequest {
  readonly method: string;
  readonly path: string;
  readonly headers: Readonly<Record<string, string | undefined>>;
  readonly body: string;
}

export interface DeviceResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: string | Buffer;
}

export interface RouterDeps {
  readonly registry: DeviceRegistry;
  readonly apiKey?: string | undefined;
  readonly session?: DeviceSessionOptions;
  readonly fetchImpl?: FetchLike;
  readonly onProbeReport?: (report: ProbeReport) => Promise<void> | void;
  readonly now?: () => Date;
}

const JSON_HEADERS = { "Content-Type": "application/json" } as const;

function json(status: number, payload: unknown): DeviceResponse {
  return { status, headers: JSON_HEADERS, body: JSON.stringify(payload) };
}

export async function handleRequest(request: DeviceRequest, deps: RouterDeps): Promise<DeviceResponse> {
  const { registry, now = () => new Date() } = deps;
  const route = `${request.method.toUpperCase()} ${request.path.split("?")[0]}`;
  const deviceId = authenticate(registry, request.headers["authorization"]);

  // Probe endpoints stay open while no tokens are configured, so the very first
  // hardware run needs no setup. Once a token exists, everything is locked.
  const probeAuthOk = registry.size === 0 || deviceId !== null;

  switch (route) {
    case "GET /v1/health":
      return json(200, { ok: true, service: "rocky-device-api", time: now().toISOString() });

    case "POST /v1/probe/echo": {
      if (!probeAuthOk) return json(401, { error: "unauthorized" });
      // Deliberately trivial: this measures the robot's uplink, nothing else.
      return json(200, { ok: true, bytes: Buffer.byteLength(request.body) });
    }

    case "GET /v1/probe/audio.wav": {
      if (!probeAuthOk) return json(401, { error: "unauthorized" });
      const wav = generateTone({ sampleRate: 16000, frequencyHz: 440, milliseconds: 600, amplitude: 0.4 });
      return {
        status: 200,
        headers: { "Content-Type": "audio/wav", "Content-Length": String(wav.length) },
        body: wav,
      };
    }

    case "POST /v1/probe/report": {
      if (!probeAuthOk) return json(401, { error: "unauthorized" });
      let parsed: unknown;
      try {
        parsed = JSON.parse(request.body);
      } catch {
        return json(400, { error: "invalid JSON" });
      }
      if (!isProbeReport(parsed)) return json(400, { error: "not a rocky-cyberpi-stage1 probe report" });
      await deps.onProbeReport?.(parsed);
      return json(200, { ok: true, checks: parsed.checks?.length ?? 0 });
    }

    case "POST /v1/device/session": {
      // Never open: this one spends money.
      if (deviceId === null) return json(401, { error: "unauthorized" });
      if (!deps.apiKey) return json(503, { error: "OPENAI_API_KEY is not configured on the device API" });
      try {
        const secret = await mintDeviceSession({
          ...(deps.session ?? {}),
          apiKey: deps.apiKey,
          deviceId,
          ...(deps.fetchImpl ? { fetchImpl: deps.fetchImpl } : {}),
        });
        return json(200, { ok: true, device_id: deviceId, session: secret });
      } catch (error) {
        return json(502, { error: error instanceof Error ? error.message : "session creation failed" });
      }
    }

    default:
      return json(404, { error: "not found", route });
  }
}
