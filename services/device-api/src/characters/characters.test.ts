import { describe, expect, it } from "vitest";

import { activeCharacter, buildInstructions, CHARACTERS, characterById, ROCKY } from "./index.ts";

describe("the character registry", () => {
  it("gives every character a distinct id", () => {
    const ids = CHARACTERS.map((character) => character.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("keeps Rocky as the default and only built-in character", () => {
    expect(CHARACTERS).toEqual([ROCKY]);
    expect(activeCharacter({})).toBe(ROCKY);
  });

  it("falls back rather than losing its voice over a typo", () => {
    expect(activeCharacter({ ROCKY_CHARACTER: "removed-character" })).toBe(ROCKY);
    expect(characterById("nobody")).toBeUndefined();
  });
});

describe("every character", () => {
  it.each(CHARACTERS.map((character) => [character.id, character] as const))(
    "%s keeps conduct out of its persona",
    (_id, character) => {
      // The shared block owns these rules; a character restating one is how two voices drift
      // apart on something that must never differ. Illustrating a rule with a bad line in your
      // own voice is fine and useful -- Rocky's negative examples do exactly that -- so this
      // matches the rules themselves, not their subject matter.
      expect(character.persona).not.toContain("Call remember_family_fact silently");
      expect(character.persona).not.toContain("Never tell a child to smell, taste, touch, heat, or mix");
      expect(character.persona).not.toContain("Output plain spoken text only");
    },
  );

  it.each(CHARACTERS.map((character) => [character.id, character] as const))(
    "%s finds plants gross",
    (_id, character) => {
      expect(character.persona.toLowerCase()).toContain("plant");
    },
  );

  it.each(CHARACTERS.map((character) => [character.id, character] as const))(
    "%s says who it is up front",
    (_id, character) => {
      expect(character.persona).toContain(`You are ${character.name}`);
    },
  );
});

describe("buildInstructions", () => {
  it("puts conduct after personality so it wins", () => {
    const instructions = buildInstructions(ROCKY);
    expect(instructions.startsWith("CHARACTER ESSENCE\n\n")).toBe(true);
    expect(instructions).toContain("COMMON INSTRUCTIONS — THE SAME FOR EVERY CHARACTER");
    expect(instructions.indexOf("You are Rocky")).toBeLessThan(instructions.indexOf("SPEECH AND CONDUCT"));
    expect(instructions.indexOf("CHARACTER ESSENCE")).toBeLessThan(
      instructions.indexOf("COMMON INSTRUCTIONS — THE SAME FOR EVERY CHARACTER"),
    );
  });

  it("appends extra sections last", () => {
    const instructions = buildInstructions(ROCKY, ["EXTRA SECTION"]);
    expect(instructions.endsWith("EXTRA SECTION")).toBe(true);
  });

  it("drops empty extras rather than leaving blank gaps", () => {
    expect(buildInstructions(ROCKY, ["  "])).toBe(buildInstructions(ROCKY));
  });
});

describe("Rocky", () => {
  it("favors signature connection beats over a repeated acknowledgement", () => {
    expect(ROCKY.persona).toContain('"Understand." is a regular Rocky beat');
    expect(ROCKY.persona).toContain("once every five or six turns");
    expect(ROCKY.persona).toContain("These are frequent Rocky connection beats");
    expect(ROCKY.persona).toContain("roughly one of every four turns");
    expect(ROCKY.persona).toContain('"Amaze. Amaze. Amaze."');
    expect(ROCKY.persona).toContain('"Fist my bump."');
  });
});
