#!/usr/bin/env node
// Dumps Rocky's fixed session plus a safe client-synthesized template for generated personalities.
// Run from apps/ios/scripts/generate.sh, not directly.

import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { CHARACTERS, ROCKY } from "../../../services/device-api/src/characters/index.ts";
import { createDeviceSessionConfig, DEFAULT_MODEL } from "../../../services/device-api/src/session.ts";

const model = process.env["ROCKY_REALTIME_MODEL"] ?? DEFAULT_MODEL;
const defaultCharacter = ROCKY;
const customPersonaToken = "__ROCKY_CUSTOM_PERSONA__";
// Only override the character's own voice when one was asked for explicitly -- passing a default
// here would silently outrank every character's choice.
const voice = process.env["ROCKY_VOICE"];
const characters = CHARACTERS.map((character) => ({
  id: character.id,
  name: character.name,
  summary: character.summary,
  session: createDeviceSessionConfig({ model, character, ...(voice ? { voice } : {}) }),
}));
const customSession = createDeviceSessionConfig({
  model,
  character: {
    id: "custom-template",
    name: "Custom",
    summary: "Runtime-created personality",
    voice: { provider: "local" },
    cadence: ROCKY.cadence,
    persona: customPersonaToken,
  },
});

const outPath = fileURLToPath(new URL("../Rocky/Resources/RealtimeSessionConfig.json", import.meta.url));
await writeFile(
  outPath,
  JSON.stringify(
    {
      default_character_id: defaultCharacter.id,
      characters,
      custom_persona_token: customPersonaToken,
      custom_session: customSession,
    },
    null,
    2,
  ),
);
const summary = characters
  .map(({ id, session }) => {
    const provider = CHARACTERS.find((character) => character.id === id)?.voice.provider;
    return `${id}:${provider === "openai" ? `openai:${session.audio.output.voice}` : provider}`;
  })
  .join(", ");
console.log(
  `==> Wrote ${characters.length} character configs (default=${defaultCharacter.id}, model=${model}, voices=${summary}) to ${outPath}`,
);
