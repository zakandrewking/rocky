#!/usr/bin/env node
// Dumps the same Realtime session config services/device-api mints with (persona, tools, voice,
// model) as a bundled JSON resource -- so the iOS app can call OpenAI's client_secrets endpoint
// directly, with the real key baked in (see generate.sh), while Rocky's persona still has exactly
// one definition in the repo (services/device-api/src/session.ts -> apps/desktop/src/main/prompt.ts).
// Run from apps/ios/scripts/generate.sh, not directly.

import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { activeCharacter } from "../../../services/device-api/src/characters/index.ts";
import { createDeviceSessionConfig, DEFAULT_MODEL } from "../../../services/device-api/src/session.ts";

const model = process.env["ROCKY_REALTIME_MODEL"] ?? DEFAULT_MODEL;
const character = activeCharacter();
// Only override the character's own voice when one was asked for explicitly -- passing a default
// here would silently outrank every character's choice.
const voice = process.env["ROCKY_VOICE"];
const session = createDeviceSessionConfig({ model, character, ...(voice ? { voice } : {}) });

const outPath = fileURLToPath(new URL("../Rocky/Resources/RealtimeSessionConfig.json", import.meta.url));
await writeFile(outPath, JSON.stringify({ session }, null, 2));
const spokenBy = character.voice.provider === "hume" ? "hume" : `openai:${session.audio.output.voice}`;
console.log(`==> Wrote session config for ${character.name} (model=${model}, voice=${spokenBy}) to ${outPath}`);
