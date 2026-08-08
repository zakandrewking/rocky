# Voice-volume-controlled driving: problem statement

Written after a live iteration session (2026-08-08) that pushed seven increasingly-refined
versions of a "drive faster when it's louder" payload over the OTA bootstrap loop
(`apps/robot/steps/step05_loudness_drive.py` through `step11_loudness_drive_tuned.py`), each
tested live on real hardware in minutes rather than hours. None of them reached the actual goal.
This is what was learned, so the next design pass starts from real findings instead of guesses.

## Goal

Reliable voice-volume-controlled driving: speed maps smoothly from a full stop to max speed based
on live sound level from the onboard mic, robust to slight ambient background noise drift, with no
feedback loop from the robot's own motor noise.

## Expected real usage

- A sustained loud sound (e.g. a scream) lasting up to ~10-15 seconds should reach and hold max
  speed quickly, not slowly ramp up or fail to saturate.
- A quieter, sustained sound afterward (e.g. talking, moaning) should track proportionally lower
  speed — not snap to zero, and not stay pinned at whatever the loud phase reached.
- Background noise drifts slightly session to session; the system shouldn't need re-tuning every
  time, and critically, must not become *less* sensitive as a side effect of reacting to loud
  sound (this happened — see v6 below).

## What's confirmed and usable

- `cyberpi.get_loudness()` returns a live scalar loudness reading. It's in Makeblock's *published*
  API (`apps/cyberpi/docs/cyberos-api-surface.md`'s audio table) rather than something found by
  probing undocumented internals, so it's on firmer ground than most `cyberpi`/`mbuild` findings
  elsewhere in this project. **What's still unknown: its actual numeric range, and whether it
  behaves linearly or logarithmically with real sound pressure.** Every version below picked its
  sensitivity constants by guessing and watching behavior — never from real recorded numbers.
- `mbot2.drive_speed(em1, em2)` is confirmed controllable, and direction is now known empirically:
  `drive_speed(+RPM, -RPM)` drives forward. A real, if informal, data point for STEPS.md step 8,
  which is otherwise still open.
- The OTA bootstrap (STEPS.md step 4b) is what made this entire session possible: roughly a dozen
  payload versions pushed and observed live in one sitting, zero USB or mBlock involved.

## The core physical problem: acoustic self-noise feedback

The robot's own motors/wheels are loud enough that its own microphone picks them up as "loud."
Any scheme that reads the mic *while the motor is running* risks a feedback loop: driving → its
own noise registers as continued external loudness → keeps driving. Observed directly in v3: the
robot locked in at max speed and stayed there with no external sound needed to sustain it.

## What was tried, in order, and exactly why each fell short

| Version | Approach | Failure |
| --- | --- | --- |
| v1 (`step05`) | Fixed-duration burst above a threshold | Safe (small, bounded nudge) but binary, not "fluid" — the actual complaint that started v2 |
| v2 (`step06`) | Continuous speed proportional to a *lifetime* min/max range | The lifetime max only ever ratchets upward and never relaxes — one loud spike permanently desensitizes everything after it ("not very sensitive") |
| v3 (`step07`) | Continuous speed, leaky-minimum floor (safe against loud spikes), no listen/drive separation | **The feedback loop.** Reading the mic while driving means self-noise gets misread as sustained external loudness; nothing distinguishes the two. Locked in at max RPM |
| v4 (`step08`) | Alternating listen (motors off) / drive (motors on) phases | Structurally avoids the feedback loop — correct idea, kept in v7 — but wasn't tuned or tested on its own merits before the self-noise-model detour below |
| v5 (`step09`) | Continuous driving; model self-noise as `floor + K·rpm`, learn `K` from one brief low-speed probe, subtract predicted self-noise from live readings | Clever in principle, but `calibrate()` blindly trusted whatever it sampled *at that instant* as "quiet" — with no check that the environment was actually quiet then |
| v6 (`step10`) | Same as v5, plus a forced periodic stop (hard time ceiling) to guarantee recalibration can't deadlock | Fixed the deadlock, but forced recalibration during a *still-loud* moment (e.g. mid-scream) sampled the scream itself as the new "ambient floor" — permanently raising it. **This is exactly the reported bug**: the longer/more continuously she screamed, the less sensitive it got, because every forced recalibration during the scream made the floor track the scream upward |
| v7 (`step11`) | Back to listen/drive alternation (v4's structure) with the *safe* leaky-minimum floor (only ever lowered by a genuinely quiet reading, never raised by a loud one), short listen window (80ms) / long drive window (500ms) | No more feedback loop, no more floor corruption — but reported as "little bursts, basically the same speed all the time": close to binary (off or near-max) rather than a smooth continuum |

## Why v7 is probably still binary-feeling

The guessed `SENSITIVITY` constant (10) is most likely far smaller than the real gap between
quiet and loud-speech readings from `get_loudness()`, so almost any real sound instantly saturates
`level` to 1.0 — meaning "driving" always means "near max RPM," regardless of how loud the sound
actually was. This is the same root issue as every version above: **no version of this experiment
has ever used a real recorded number for quiet vs. normal vs. loud vs. scream.** Every threshold
has been picked by feel and adjusted after one live test each time, which is fast (thanks to OTA)
but was never going to converge on a good curve by itself.

A secondary, untested possibility: the 80ms listen window fires immediately after the motor stops,
which may be too soon for mechanical vibration/ringing to settle — worth checking whether a short
delay between motor-stop and mic-read changes anything.

## What the fresh design pass needs

1. **Real calibration data, gathered deliberately, not guessed.** Before picking any mapping
   function, run an explicit calibration conversation with a person:
   - Silence for ~5s → record several loudness samples (true ambient floor, and its natural
     jitter).
   - Normal speaking volume for ~5s → record samples.
   - Loud / near-scream volume for ~5s → record samples.
   - Motor run at 2-3 known RPM values, person asked to stay silent for each → record loudness
     samples per RPM (a clean, supervised version of v5/v6's self-noise-per-RPM idea, done
     deliberately under confirmed-quiet conditions instead of auto-probed at an arbitrary moment).

   This needs a real way to get the numbers off the device — reading them character-by-character
   off a 128×128 screen doesn't scale past a couple of data points. Simplest fix: have the
   calibration payload stream each sample back over a socket (the existing push connection, or a
   small dedicated telemetry endpoint) so real numbers land on the laptop to log and look at,
   rather than being eyeballed off the screen one at a time.

2. **A mapping fit to that real data**, not a guessed linear constant — quite possibly
   non-linear (both loudness sensors and human vocal effort commonly behave logarithmically, not
   linearly), and explicitly anchored to where "normal," "loud," and "scream" actually land
   numerically, so a real scream reliably reaches max speed without the mapping being either too
   insensitive (v6) or effectively binary (v7).

3. **Self-noise handling that can't corrupt itself.** The hard lesson from v5/v6: any step that
   updates a "floor" or "self-noise" estimate must never blindly trust a single instantaneous
   sample without some confirmation the assumption (quiet, or motor-only) actually held at that
   moment. The property that did work in v7 — a floor that can only be *lowered* by a genuinely
   quiet reading, never raised by a loud one — should carry forward into whatever comes next.

4. **Decide deliberately between two real architectures**, informed by the calibration data
   rather than assumed:
   - Keep the listen/drive time-alternation (avoids the feedback loop by construction, simple,
     but caps responsiveness/smoothness — tune window sizes using real data on how quickly a
     scream needs to register).
   - Return to self-noise subtraction (allows continuous driving with no motors-off pauses), but
     only if the per-RPM self-noise constants come from the deliberate calibration pass above,
     under confirmed-quiet conditions — not auto-probed live the way v5/v6 did.

## Open questions to settle before or during the fresh pass

- What is `get_loudness()`'s actual numeric range and behavior (linear vs. logarithmic) across
  quiet, normal, loud, and scream conditions?
- How much does self-noise actually vary with RPM, in real numbers — is v5's "roughly
  proportional to RPM" assumption even correct?
- Is there a minimum motor-off settle time needed after stopping before a mic reading is
  trustworthy (mechanical vibration/ringing)?
- What listen/drive window sizes (if keeping the alternation approach) best balance
  responsiveness against smoothness for a sound sustained over ~10-15 seconds?
