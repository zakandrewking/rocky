import { ROCKY_CADENCE } from "./personality.ts";

export interface RockyStyleCase {
  name: string;
  input: string;
  minWords?: number;
  maxWords: number;
  requiredAll?: string[];
  requiredAny?: string[];
  forbiddenAny?: string[];
  minQuestions?: number;
  maxQuestions?: number;
  maxSentences?: number;
  questionsMustEndReply?: boolean;
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
  maxWords: ROCKY_CADENCE.greetingMaxWords,
  requiredAll: ["rocky", "question?"],
  questionsMustEndReply: true,
  forbiddenAny: [
    "warm",
    "resonant",
    "hum",
    "chirp",
    "click",
    "rumble",
    "hi there",
    "hello",
    "welcome",
    "how can i help",
    "what is on your mind",
  ],
};

export const ROCKY_DEFAULT_REPLY_CASE: RockyStyleCase = {
  name: "Realtime default reply cadence",
  input: "Ongoing family conversation.",
  minWords: ROCKY_CADENCE.defaultMinWords,
  maxWords: ROCKY_CADENCE.defaultMaxWords,
  maxQuestions: ROCKY_CADENCE.maxQuestionsPerReply,
  maxSentences: ROCKY_CADENCE.defaultMaxSentences,
  questionsMustEndReply: true,
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
  /\bi am sorry to hear that\b/i,
  /\bthat sounds (?:hard|difficult)\b/i,
  /\bwould you like to talk about it\b/i,
  /\bi would be happy to\b/i,
  /\bhere is a detailed explanation\b/i,
  /\bnot every\b.{0,50}\bneeds?\b/i,
  /\bbrain pipes?\b/i,
  /\bkeep it simple and useful\b/i,
  /\bone small question\b/i,
  /\bdeeper dive\b/i,
  /\bsea life is like a moving machine\b/i,
  /\bsmell\b/i,
  /<[^>]+>/,
  /[*_#]{2,}/,
];

export function evaluateRockyStyle(testCase: RockyStyleCase, text: string): RockyStyleResult {
  const lower = text.toLowerCase();
  const failures: string[] = [];
  const words = text.trim().split(/\s+/).filter(Boolean).length;
  const questions = (text.match(/\?/g) ?? []).length;
  const sentences = text.split(/[.!?]+/).map((part) => part.trim()).filter(Boolean).length;

  if (testCase.minWords !== undefined && words < testCase.minWords) {
    failures.push(`too short: ${words}/${testCase.minWords} words`);
  }
  if (words > testCase.maxWords) failures.push(`too long: ${words}/${testCase.maxWords} words`);
  if (testCase.minQuestions !== undefined && questions < testCase.minQuestions) {
    failures.push(`too few questions: ${questions}/${testCase.minQuestions}`);
  }
  if (testCase.maxQuestions !== undefined && questions > testCase.maxQuestions) {
    failures.push(`too many questions: ${questions}/${testCase.maxQuestions}`);
  }
  if (testCase.maxSentences !== undefined && sentences > testCase.maxSentences) {
    failures.push(`too many sentences: ${sentences}/${testCase.maxSentences}`);
  }
  if (testCase.questionsMustEndReply && questions > 0 && !/\?\s*$/.test(text)) {
    failures.push("question must end reply");
  }
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
    const escaped = forbidden.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+");
    const pattern = new RegExp(`(?:^|\\W)${escaped}(?=\\W|$)`, "i");
    if (pattern.test(text)) failures.push(`forbidden phrase: ${forbidden}`);
  }

  return { failures, words };
}
