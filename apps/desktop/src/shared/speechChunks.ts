export function splitSpeechChunks(
  buffer: string,
  delta: string,
  flush = false,
): { complete: string[]; remainder: string } {
  let remainder = `${buffer}${delta}`;
  const complete: string[] = [];
  const sentenceBoundary = /[.!?](?:["')\]]+)?\s+/;

  while (remainder) {
    const match = sentenceBoundary.exec(remainder);
    if (match?.index !== undefined) {
      const end = match.index + match[0].length;
      complete.push(remainder.slice(0, end).trim());
      remainder = remainder.slice(end);
      continue;
    }
    if (remainder.length >= 120) {
      const breakAt = remainder.lastIndexOf(" ", 100);
      if (breakAt > 20) {
        complete.push(remainder.slice(0, breakAt).trim());
        remainder = remainder.slice(breakAt + 1);
        continue;
      }
    }
    break;
  }

  if (flush && remainder.trim()) {
    complete.push(remainder.trim());
    remainder = "";
  }
  return { complete, remainder };
}
