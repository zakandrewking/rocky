#!/usr/bin/env node
// Dumps the Realtime session config services/device-api mints for every registered character
// (persona, tools, voice, model) as one bundled catalog. The iOS app can select at runtime and call
// OpenAI's client_secrets endpoint directly while personalities remain defined only in
// services/device-api.
// Run from apps/ios/scripts/generate.sh, not directly.

import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { activeCharacter, CHARACTERS } from "../../../services/device-api/src/characters/index.ts";
import { createDeviceSessionConfig, DEFAULT_MODEL } from "../../../services/device-api/src/session.ts";

const model = process.env["ROCKY_REALTIME_MODEL"] ?? DEFAULT_MODEL;
const defaultCharacter = activeCharacter();
// Only override the character's own voice when one was asked for explicitly -- passing a default
// here would silently outrank every character's choice.
const voice = process.env["ROCKY_VOICE"];
const characters = CHARACTERS.map((character) => ({
  id: character.id,
  name: character.name,
  summary: character.summary,
  session: createDeviceSessionConfig({ model, character, ...(voice ? { voice } : {}) }),
}));

const outPath = fileURLToPath(new URL("../Rocky/Resources/RealtimeSessionConfig.json", import.meta.url));
await writeFile(
  outPath,
  JSON.stringify({ default_character_id: defaultCharacter.id, characters }, null, 2),
);
const summary = characters
  .map(({ id, session }) => `${id}:${session.output_modalities[0] === "text" ? "hume" : `openai:${session.audio.output.voice}`}`)
  .join(", ");
console.log(
  `==> Wrote ${characters.length} character configs (default=${defaultCharacter.id}, model=${model}, voices=${summary}) to ${outPath}`,
);
