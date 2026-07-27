import { describe, expect, it } from "vitest";

import { authenticate, parseDeviceTokens } from "./auth.ts";

const TOKEN = "0123456789abcdef0123";
const OTHER = "fedcba98765432100987";

describe("parseDeviceTokens", () => {
  it("parses comma-separated device:token pairs", () => {
    const registry = parseDeviceTokens(` rocky-mbot2:${TOKEN} , spare:${OTHER} `);
    expect([...registry.entries()]).toEqual([
      ["rocky-mbot2", TOKEN],
      ["spare", OTHER],
    ]);
  });

  it("returns an empty registry when unset", () => {
    expect(parseDeviceTokens(undefined).size).toBe(0);
    expect(parseDeviceTokens("").size).toBe(0);
  });

  it("rejects tokens too short to be worth trusting", () => {
    expect(parseDeviceTokens("rocky:short").size).toBe(0);
  });

  it("ignores malformed entries without dropping good ones", () => {
    const registry = parseDeviceTokens(`no-separator,:${TOKEN},rocky:${OTHER}`);
    expect([...registry.keys()]).toEqual(["rocky"]);
  });

  it("keeps colons inside the token itself", () => {
    const registry = parseDeviceTokens(`rocky:aaaa:bbbb:cccc:dddd:eeee`);
    expect(registry.get("rocky")).toBe("aaaa:bbbb:cccc:dddd:eeee");
  });
});

describe("authenticate", () => {
  const registry = parseDeviceTokens(`rocky-mbot2:${TOKEN},spare:${OTHER}`);

  it("returns the device id for a valid bearer token", () => {
    expect(authenticate(registry, `Bearer ${TOKEN}`)).toBe("rocky-mbot2");
    expect(authenticate(registry, `bearer ${OTHER}`)).toBe("spare");
  });

  it("rejects unknown, empty, and malformed credentials", () => {
    expect(authenticate(registry, `Bearer ${"z".repeat(20)}`)).toBeNull();
    expect(authenticate(registry, "Bearer ")).toBeNull();
    expect(authenticate(registry, TOKEN)).toBeNull();
    expect(authenticate(registry, undefined)).toBeNull();
  });

  it("rejects a token that is merely a prefix of a real one", () => {
    expect(authenticate(registry, `Bearer ${TOKEN.slice(0, 10)}`)).toBeNull();
  });

  it("authenticates nobody when no devices are registered", () => {
    expect(authenticate(parseDeviceTokens(""), `Bearer ${TOKEN}`)).toBeNull();
  });
});
