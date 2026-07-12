import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import {
  AlignmentType,
  Document,
  HeadingLevel,
  LevelFormat,
  Packer,
  Paragraph,
  ShadingType,
  TextRun,
} from "docx";

import type { HowToDocResult, HowToDocSection, HowToDocSpec } from "../shared/types";

const MAX_ITEMS = 40;
const MAX_TEXT_LENGTH = 600;

function cleanText(value: unknown, fallback: string, maxLength = MAX_TEXT_LENGTH): string {
  const text = typeof value === "string" ? value : "";
  const clean = text.replace(/\s+/g, " ").trim().slice(0, maxLength);
  return clean || fallback;
}

function cleanList(value: unknown, maxItems = MAX_ITEMS): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => cleanText(item, "", MAX_TEXT_LENGTH))
    .filter(Boolean)
    .slice(0, maxItems);
}

function safeFilename(value: unknown, fallback: string): string {
  const source = cleanText(value, fallback, 90).replace(/\.docx$/i, "");
  const clean = source
    .replace(/[^\w .-]+/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^[.-]+|[.-]+$/g, "");
  return `${clean || fallback}.docx`;
}

function cleanSections(value: unknown): HowToDocSection[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => {
      const record = item && typeof item === "object" ? item as Record<string, unknown> : {};
      return {
        heading: cleanText(record.heading, "", 120),
        bullets: cleanList(record.bullets, 12),
      };
    })
    .filter((section) => section.heading && section.bullets.length)
    .slice(0, 8);
}

export function normalizeHowToDocSpec(value: unknown): HowToDocSpec {
  const record = value && typeof value === "object" ? value as Record<string, unknown> : {};
  const title = cleanText(record.title, "Rocky How-To Guide", 120);
  const steps = cleanList(record.steps, 30);
  return {
    title,
    filename: safeFilename(record.filename, title),
    purpose: cleanText(record.purpose, "", 500),
    materials: cleanList(record.materials, 30),
    steps: steps.length ? steps : ["Decide goal.", "Gather safe materials.", "Try one small step.", "Check result."],
    safetyNotes: cleanList(record.safetyNotes, 12),
    tips: cleanList(record.tips, 16),
    sections: cleanSections(record.sections),
  };
}

function heading(text: string, level: typeof HeadingLevel[keyof typeof HeadingLevel]): Paragraph {
  return new Paragraph({
    text,
    heading: level,
    spacing: { before: 260, after: 120 },
  });
}

function bullet(text: string): Paragraph {
  return new Paragraph({
    text,
    numbering: { reference: "rocky-bullets", level: 0 },
    spacing: { after: 80 },
  });
}

function numbered(text: string): Paragraph {
  return new Paragraph({
    text,
    numbering: { reference: "rocky-steps", level: 0 },
    spacing: { after: 120 },
  });
}

export async function writeHowToDoc(value: unknown, directory: string): Promise<HowToDocResult> {
  const spec = normalizeHowToDocSpec(value);
  await mkdir(directory, { recursive: true });
  const filename = spec.filename ?? safeFilename(undefined, spec.title);
  const filePath = path.join(directory, filename);

  const children: Paragraph[] = [
    new Paragraph({
      children: [new TextRun({ text: spec.title, bold: true, size: 52, color: "1F3A35" })],
      spacing: { after: 120 },
    }),
    new Paragraph({
      children: [new TextRun({ text: "A compact Rocky how-to guide.", italics: true, color: "58635F" })],
      spacing: { after: 280 },
    }),
  ];

  if (spec.purpose) {
    children.push(
      heading("Goal", HeadingLevel.HEADING_1),
      new Paragraph({ text: spec.purpose, spacing: { after: 160 } }),
    );
  }

  if (spec.safetyNotes?.length) {
    children.push(
      new Paragraph({
        children: [new TextRun({ text: "Safety first", bold: true })],
        shading: { type: ShadingType.CLEAR, fill: "FFF1D6", color: "auto" },
        spacing: { before: 120, after: 120 },
      }),
      ...spec.safetyNotes.map(bullet),
    );
  }

  if (spec.materials?.length) {
    children.push(heading("What you need", HeadingLevel.HEADING_1), ...spec.materials.map(bullet));
  }

  children.push(heading("Steps", HeadingLevel.HEADING_1), ...spec.steps.map(numbered));

  for (const section of spec.sections ?? []) {
    children.push(heading(section.heading, HeadingLevel.HEADING_2), ...section.bullets.map(bullet));
  }

  if (spec.tips?.length) {
    children.push(heading("Useful tricks", HeadingLevel.HEADING_1), ...spec.tips.map(bullet));
  }

  const doc = new Document({
    creator: "Rocky",
    title: spec.title,
    description: "Local Rocky how-to guide",
    numbering: {
      config: [
        {
          reference: "rocky-steps",
          levels: [{
            level: 0,
            format: LevelFormat.DECIMAL,
            text: "%1.",
            alignment: AlignmentType.START,
            style: { paragraph: { indent: { left: 720, hanging: 360 } } },
          }],
        },
        {
          reference: "rocky-bullets",
          levels: [{
            level: 0,
            format: LevelFormat.BULLET,
            text: "•",
            alignment: AlignmentType.START,
            style: { paragraph: { indent: { left: 720, hanging: 360 } } },
          }],
        },
      ],
    },
    styles: {
      paragraphStyles: [
        {
          id: "Normal",
          name: "Normal",
          run: { font: "Aptos", size: 22, color: "17211E" },
          paragraph: { spacing: { line: 276, after: 90 } },
        },
        {
          id: "Heading1",
          name: "Heading 1",
          basedOn: "Normal",
          next: "Normal",
          quickFormat: true,
          run: { font: "Aptos Display", size: 30, bold: true, color: "1F3A35" },
        },
        {
          id: "Heading2",
          name: "Heading 2",
          basedOn: "Normal",
          next: "Normal",
          quickFormat: true,
          run: { font: "Aptos Display", size: 25, bold: true, color: "38544D" },
        },
      ],
    },
    sections: [{
      properties: {
        page: {
          margin: { top: 1080, right: 1080, bottom: 1080, left: 1080 },
          size: { width: 12_240, height: 15_840 },
        },
      },
      children,
    }],
  });

  await writeFile(filePath, await Packer.toBuffer(doc));

  return {
    path: filePath,
    filename,
    title: spec.title,
    steps: spec.steps,
  };
}
