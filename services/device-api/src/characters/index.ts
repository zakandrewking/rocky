import { ROCKY } from "./rocky.ts";
import { SHARED_BEHAVIOUR } from "./shared.ts";
import type { Character } from "./types.ts";

export type { Character, CharacterCadence, CharacterVoice } from "./types.ts";
export { SHARED_BEHAVIOUR } from "./shared.ts";
export { ROCKY } from "./rocky.ts";

export const CHARACTERS: readonly Character[] = [ROCKY];

export const DEFAULT_CHARACTER_ID = ROCKY.id;

export function characterById(id: string | undefined): Character | undefined {
  return CHARACTERS.find((character) => character.id === id?.trim().toLowerCase());
}

/**
 * Who is speaking, selected by ROCKY_CHARACTER. An unknown id falls back to the default rather
 * than throwing: a typo in an env var should not take the robot's voice away entirely, and the
 * warning says what happened.
 */
export function activeCharacter(env: NodeJS.ProcessEnv = process.env): Character {
  const requested = env["ROCKY_CHARACTER"];
  if (!requested) return ROCKY;
  const found = characterById(requested);
  if (found) return found;
  console.warn(
    `Unknown ROCKY_CHARACTER "${requested}"; falling back to ${DEFAULT_CHARACTER_ID}. Known: ${CHARACTERS.map((c) => c.id).join(", ")}`,
  );
  return ROCKY;
}

/**
 * The full system prompt for a character: who they are, then how everyone behaves. Conduct comes
 * last so it wins any argument with personality.
 */
export function buildInstructions(character: Character, extraSections: readonly string[] = []): string {
  return [character.persona, SHARED_BEHAVIOUR, ...extraSections].filter((section) => section.trim()).join("\n\n");
}
