import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

import type { FamilyMemory, MemoryFactInput, MemoryFactResult } from "../shared/types";

const MAX_PEOPLE = 12;
const MAX_FACTS_PER_PERSON = 20;
const SENSITIVE_PATTERN = /\b(?:address|credit card|email|password|passcode|phone number|school|social security|ssn)\b/i;

function emptyMemory(): FamilyMemory {
  return { version: 1, updatedAt: new Date(0).toISOString(), people: [] };
}

function cleanText(value: unknown, label: string, maxLength: number): string {
  if (typeof value !== "string") throw new Error(`${label} must be text.`);
  const clean = value.trim().replace(/\s+/g, " ").slice(0, maxLength);
  if (!clean) throw new Error(`${label} is required.`);
  return clean;
}

export async function readFamilyMemory(filePath: string): Promise<FamilyMemory> {
  try {
    const parsed = JSON.parse(await readFile(filePath, "utf8")) as Partial<FamilyMemory>;
    if (parsed.version !== 1 || !Array.isArray(parsed.people)) return emptyMemory();
    return {
      version: 1,
      updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : new Date(0).toISOString(),
      people: parsed.people.slice(0, MAX_PEOPLE).map((person) => ({
        name: cleanText(person.name, "Person", 40),
        facts: Array.isArray(person.facts)
          ? person.facts.slice(0, MAX_FACTS_PER_PERSON).map((fact) => ({
              text: cleanText(fact.text, "Memory fact", 240),
              createdAt: typeof fact.createdAt === "string" ? fact.createdAt : new Date(0).toISOString(),
            }))
          : [],
      })),
    };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || error instanceof SyntaxError) return emptyMemory();
    throw error;
  }
}

async function writeFamilyMemory(filePath: string, memory: FamilyMemory): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporaryPath = `${filePath}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(memory, null, 2)}\n`, "utf8");
  await rename(temporaryPath, filePath);
}

export async function rememberFamilyFact(
  filePath: string,
  input: MemoryFactInput,
): Promise<MemoryFactResult> {
  const person = cleanText(input.person, "Person", 40);
  const fact = cleanText(input.fact, "Memory fact", 240);
  if (SENSITIVE_PATTERN.test(fact)) {
    throw new Error("Rocky does not store sensitive personal information.");
  }

  const memory = await readFamilyMemory(filePath);
  let personMemory = memory.people.find((item) => item.name.toLowerCase() === person.toLowerCase());
  if (!personMemory) {
    if (memory.people.length >= MAX_PEOPLE) throw new Error("Rocky's local memory is full.");
    personMemory = { name: person, facts: [] };
    memory.people.push(personMemory);
  }

  const duplicate = personMemory.facts.some((item) => item.text.toLowerCase() === fact.toLowerCase());
  if (!duplicate) {
    personMemory.facts.push({ text: fact, createdAt: new Date().toISOString() });
    if (personMemory.facts.length > MAX_FACTS_PER_PERSON) personMemory.facts.shift();
    memory.updatedAt = new Date().toISOString();
    await writeFamilyMemory(filePath, memory);
  }

  return { saved: !duplicate, person: personMemory.name, fact };
}

export function formatMemoryForPrompt(memory: FamilyMemory): string {
  if (!memory.people.some((person) => person.facts.length)) return "No saved family memories yet.";
  return memory.people
    .filter((person) => person.facts.length)
    .map((person) => `${person.name}: ${person.facts.map((fact) => fact.text).join("; ")}`)
    .join("\n");
}

