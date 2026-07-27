import { timingSafeEqual } from "node:crypto";

export type DeviceRegistry = ReadonlyMap<string, string>;

/**
 * Parses `ROCKY_DEVICE_TOKENS`, a comma-separated list of `deviceId:token`
 * pairs. Keeping the registry in the environment means no device credential
 * is ever committed, and revoking a robot is a restart away.
 */
export function parseDeviceTokens(raw: string | undefined): DeviceRegistry {
  const registry = new Map<string, string>();
  for (const entry of (raw ?? "").split(",")) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const separator = trimmed.indexOf(":");
    if (separator <= 0) continue;
    const deviceId = trimmed.slice(0, separator).trim();
    const token = trimmed.slice(separator + 1).trim();
    // A short token is worse than no token, because it looks like security.
    if (!deviceId || token.length < 16) continue;
    registry.set(deviceId, token);
  }
  return registry;
}

function constantTimeEquals(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

/** Returns the device id a bearer token belongs to, or null. */
export function authenticate(registry: DeviceRegistry, authorizationHeader: string | undefined): string | null {
  const header = (authorizationHeader ?? "").trim();
  if (!header.toLowerCase().startsWith("bearer ")) return null;
  const presented = header.slice(7).trim();
  if (!presented) return null;

  // Compare against every device rather than looking the token up, so timing
  // does not leak which device ids exist.
  let matched: string | null = null;
  for (const [deviceId, token] of registry) {
    if (constantTimeEquals(presented, token)) matched = deviceId;
  }
  return matched;
}
