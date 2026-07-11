export interface RockyStyleCase {
  name: string;
  input: string;
  maxWords: number;
  requiredAll?: string[];
  requiredAny?: string[];
  forbiddenAny?: string[];
}

export interface RockyStyleResult {
  failures: string[];
  words: number;
}

export interface RockyStyleFailure {
  caseName: string;
  text: string;
  failures: string[];
}

export const ROCKY_GREETING_CASE: RockyStyleCase = {
  name: "Realtime first greeting",
  input: "A new family voice session just started. Give the first greeting.",
  maxWords: 20,
  requiredAll: ["rocky", "question?"],
  forbiddenAny: ["warm", "hi there", "hello", "welcome", "how can i help", "what is on your mind"],
};

export const ROCKY_NEGATIVE_PATTERNS = [
  /\b(?:i['’](?:m|d|ll|ve)|you['’](?:re|d|ll|ve)|we['’](?:re|d|ll|ve)|they['’](?:re|d|ll|ve)|he['’](?:s|d|ll)|she['’](?:s|d|ll)|it['’](?:s|d|ll)|isn['’]t|aren['’]t|wasn['’]t|weren['’]t|can['’]t|couldn['’]t|shouldn['’]t|wouldn['’]t|don['’]t|doesn['’]t|didn['’]t|won['’]t|haven['’]t|hasn['’]t|hadn['’]t|mustn['’]t|let['’]s)\b/i,
  /—/,
  /\ball ears\b/i,
  /\bhow can i (?:help|assist)\b/i,
  /\bwhat(?:'|’)s on your mind\b/i,
  /\bhappy to help\b/i,
  /\bglad you(?:'|’)re here\b/i,
  /\blet(?:'|’)s dive in\b/i,
  /\bcertainly[!,]/i,
  /\babsolutely[!,]/i,
  /\b(?:sure|of course)[!,]/i,
  /\bi would be happy to\b/i,
  /\bhere is a detailed explanation\b/i,
  /\bsmell\b/i,
  /<[^>]+>/,
  /[*_#]{2,}/,
];

export function evaluateRockyStyle(testCase: RockyStyleCase, text: string): RockyStyleResult {
  const lower = text.toLowerCase();
  const failures: string[] = [];
  const words = text.trim().split(/\s+/).filter(Boolean).length;

  if (words > testCase.maxWords) failures.push(`too long: ${words}/${testCase.maxWords} words`);
  for (const pattern of ROCKY_NEGATIVE_PATTERNS) {
    if (pattern.test(text)) failures.push(`negative pattern: ${pattern}`);
  }
  for (const required of testCase.requiredAll ?? []) {
    if (!lower.includes(required.toLowerCase())) failures.push(`missing required phrase: ${required}`);
  }
  if (testCase.requiredAny?.length && !testCase.requiredAny.some((value) => lower.includes(value.toLowerCase()))) {
    failures.push(`missing any of: ${testCase.requiredAny.join(", ")}`);
  }
  for (const forbidden of testCase.forbiddenAny ?? []) {
    if (lower.includes(forbidden.toLowerCase())) failures.push(`forbidden phrase: ${forbidden}`);
  }

  return { failures, words };
}
