import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { parseDeviceTokens } from "./auth.ts";
import { saveProbeReport, summarizeProbeReport, type ProbeReport } from "./probeReport.ts";
import { handleRequest } from "./router.ts";
import { DEFAULT_MODEL, DEFAULT_VOICE } from "./session.ts";
import { buildUpgradeResponse } from "./websocket.ts";

const MAX_BODY_BYTES = 1024 * 1024;

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../../..");
const reportDirectory = path.join(repoRoot, "local-data", "cyberpi");

function readBody(request: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

export function createServer(): http.Server {
  const registry = parseDeviceTokens(process.env["ROCKY_DEVICE_TOKENS"]);
  const apiKey = process.env["OPENAI_API_KEY"];

  const server = http.createServer(async (request, response) => {
    let body = "";
    try {
      body = await readBody(request);
    } catch {
      response.writeHead(413, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ error: "request body too large" }));
      return;
    }

    const result = await handleRequest(
      {
        method: request.method ?? "GET",
        path: request.url ?? "/",
        headers: request.headers as Record<string, string | undefined>,
        body,
      },
      {
        registry,
        ...(apiKey ? { apiKey } : {}),
        session: {
          model: process.env["ROCKY_REALTIME_MODEL"] ?? DEFAULT_MODEL,
          voice: process.env["ROCKY_VOICE"] ?? DEFAULT_VOICE,
        },
        onProbeReport: async (report: ProbeReport) => {
          const savedTo = await saveProbeReport(reportDirectory, report);
          console.log(`\n${summarizeProbeReport(report)}\nSaved to ${savedTo}\n`);
        },
      },
    );

    response.writeHead(result.status, result.headers);
    response.end(result.body);
  });

  // The probe's WebSocket check: complete the handshake, then hang up. Node's
  // http server routes upgrades away from the normal request handler.
  server.on("upgrade", (request, socket) => {
    const key = request.headers["sec-websocket-key"];
    if (request.url?.startsWith("/v1/probe/ws") && typeof key === "string") {
      socket.write(buildUpgradeResponse(key));
    } else {
      socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    }
    socket.end();
  });

  return server;
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (isMain) {
  const port = Number(process.env["ROCKY_DEVICE_API_PORT"] ?? 8787);
  const host = process.env["ROCKY_DEVICE_API_HOST"] ?? "0.0.0.0";
  const registry = parseDeviceTokens(process.env["ROCKY_DEVICE_TOKENS"]);

  createServer().listen(port, host, () => {
    console.log(`Rocky device API listening on http://${host}:${port}`);
    console.log(`  devices configured: ${registry.size || "none (probe endpoints are open)"}`);
    console.log(`  OpenAI key: ${process.env["OPENAI_API_KEY"] ? "present" : "missing — /v1/device/session will 503"}`);
    console.log(`  probe reports: ${reportDirectory}`);
  });
}
