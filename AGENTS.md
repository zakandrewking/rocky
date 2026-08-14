- Work on `main` and push to `origin main` regularly as you go. No feature branches, and no pull
  requests unless asked. If a harness assigns a working branch, switch back to `main` instead.
- Keep working; don't ask for confirmation from me unless your goals are unclear or there
  are interesting/fun design decisions
- It's ok to try out a design option and then ask me if it's good
- use good software dev practices: tests, a nicely organized monorepo
- plan future steps in a TODOS.md file that you keep up to date
- Make reasonable product and technical decisions autonomously; document notable choices in
  TODOS.md
- You may install dependencies and run local services without asking
- Before pushing, run the relevant tests, typecheck, and lint; fix failures caused by your
  changes
- Never commit secrets or display values from .env; use .env.example for required variable
  names
- Prefer TypeScript and pnpm unless the existing project establishes another convention
- Keep the app runnable after each push; add setup and launch instructions to README.md
- For UI work, verify the main flow in a real browser
- Commit in small, coherent increments with descriptive messages
- After you commit, keep working; do not pause unless instructed to do so or you genuinely need
  user feedback
- Do not overwrite unrelated user changes in a dirty worktree
- After you commit, keep working. Do not pause unless instructed to do so, or if you really 
  need feedback

## Judgment learned from real incidents (not codebase facts — those belong in the code itself)

- On a single-threaded embedded device, the code path that would recover from a mistake and the
  code path the mistake is in are often the same one. A hang anywhere in a boot/init path that
  always runs blocks everything downstream of it, including your own ability to push a fix. Before
  adding a call to a path like that, ask "what breaks if this hangs?", not just "what breaks if
  this errors?" — a try/except doesn't help against a call that never returns. This is a stronger
  bar than most CI-tested software needs, and it's the reason `apps/robot/steps/` and
  `apps/cyberpi/`'s recovery scripts exist as a category, not just as one-off scripts. Reach for
  that same discipline (prove new firmware/device-side behavior in the smallest, most disposable
  program possible, isolated from anything you depend on to recover) any time you're extending
  either.
- "Check for published source before reverse-engineering" (see CLAUDE.md) applies just as much to
  *whether an API exists at all* as it does to *what a device does*. A five-minute check of
  upstream source settles "does this platform have `X`" for certain; a live probe on hardware that
  can get stuck settles it at real risk. Default to the cheaper, safer check first, especially
  for anything you're about to call from a path that can't afford to hang.
- When two independently-different approaches to the same goal both fail, that's evidence of a
  structural reason, not two bad tries — stop and look for the platform-level explanation (source,
  docs, changelogs) before reaching for a third, riskier attempt. Escalating risk after repeated
  failures is usually backwards; the right move is usually to step back and ask why the *category*
  of approach keeps failing.
- Root-cause the story that's chronologically closest to the failure only after checking for
  evidence that would actually distinguish it from other explanations. "This call ran right before
  things broke" is a hypothesis, not a diagnosis — in this project's own postmortem, the real
  cause was a different call than the first, plausible-sounding guess, and the evidence that
  settled it (the failure recurring with no client ever connecting) was already available before
  writing the first, wrong explanation down.
- When a live system doesn't behave as your working theory predicts, check your own tooling and
  assumptions before re-diagnosing the system — stale caches, your own network state, or a wrong
  premise are at least as likely as a new bug in the thing you're actually investigating.
