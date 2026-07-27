import { createHash } from "node:crypto";

/** RFC 6455 magic string. */
const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export function computeAcceptKey(clientKey: string): string {
  return createHash("sha1")
    .update(clientKey + WEBSOCKET_GUID)
    .digest("base64");
}

/**
 * The 101 response for the probe's upgrade check.
 *
 * The service does not speak WebSocket yet — Stage 2 needs a real client. All
 * the probe has to learn is whether a CyberOS socket can complete the handshake
 * at all, which is the thing most likely to be missing.
 */
export function buildUpgradeResponse(clientKey: string): string {
  return [
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${computeAcceptKey(clientKey)}`,
    "",
    "",
  ].join("\r\n");
}
