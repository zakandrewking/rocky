export interface ConversationTurn {
  role: "you" | "rocky";
  text: string;
}

const TURN_HEADING = /^\*\*(You|Rocky)(?: · [^*]+)?\*\*\s*$/;

export function parseConversationTurns(markdown: string): ConversationTurn[] {
  const turns: ConversationTurn[] = [];
  let current: ConversationTurn | undefined;

  const finishCurrent = (): void => {
    if (!current) return;
    current.text = current.text.trim().replace(/\s*\n\s*/g, " ");
    if (current.text) turns.push(current);
    current = undefined;
  };

  for (const line of markdown.split(/\r?\n/)) {
    const heading = line.match(TURN_HEADING);
    if (heading) {
      finishCurrent();
      current = { role: heading[1]!.toLowerCase() as ConversationTurn["role"], text: "" };
      continue;
    }

    if (/^\*\*.+\*\*\s*$/.test(line)) {
      finishCurrent();
      continue;
    }
    if (current) current.text += `${line}\n`;
  }

  finishCurrent();
  return turns;
}

export function isGreetingTurn(
  turns: ConversationTurn[],
  turnIndex: number,
  assumeFirstRockyIsGreeting = false,
): boolean {
  const rockyTurnIndex = turns.slice(0, turnIndex + 1).filter((turn) => turn.role === "rocky").length - 1;
  if (assumeFirstRockyIsGreeting && rockyTurnIndex === 0) return true;

  const previous = turns[turnIndex - 1];
  return previous?.role === "you"
    && /new family (?:voice |text )?conversation.*first greeting/i.test(previous.text);
}
