export function splitSpeechChunks(
  buffer: string,
  delta: string,
  flush = false,
): { complete: string[]; remainder: string } {
  let remainder = `${buffer}${delta}`;
  const complete: string[] = [];
  const sentenceBoundary = /[.!?](?:["')\]]+)?(?:\s+|$)/g;
  const minChunkLength = 180;
  const maxChunkLength = 340;

  while (remainder) {
    sentenceBoundary.lastIndex = 0;
    let sentenceEnd = -1;
    for (let match = sentenceBoundary.exec(remainder); match; match = sentenceBoundary.exec(remainder)) {
      const end = match.index + match[0].length;
      if (end > maxChunkLength) break;
      sentenceEnd = end;
      if (end >= minChunkLength) break;
    }
    if (sentenceEnd >= minChunkLength || (flush && sentenceEnd > 0)) {
      complete.push(remainder.slice(0, sentenceEnd).trim());
      remainder = remainder.slice(sentenceEnd).trimStart();
      continue;
    }
    if (remainder.length >= maxChunkLength) {
      const breakAt = remainder.lastIndexOf(" ", maxChunkLength);
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
