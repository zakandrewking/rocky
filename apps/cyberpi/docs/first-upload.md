# Running your first step on the CyberPi

Setup instructions for step 1. Everything here applies to steps 2–12 as well, so this is a
one-time read.

Nothing in this process is destructive. You are writing to one of CyberPi's program slots, the
same thing any mBlock lesson does, and the board's normal menu is always a joystick press away.

## What you need

- a CyberPi (on its own, or plugged into the mBot2 shield — step 1 does not care)
- a USB-C cable that carries **data**, not just power. A charge-only cable is the single most
  common reason nothing shows up.
- mBlock 5, the **desktop** app, from <https://mblock.cc/pages/downloads>

Use the desktop app rather than the web editor. The web version needs a helper service called
mLink to reach USB devices, which is one more thing to debug on your first run.

## Setup, once

**1. Power on.** Slide the switch on the side of the CyberPi. You should get the CyberOS home
screen. Connect the USB-C cable to your computer.

**2. Add the device.** In mBlock 5, the device panel starts on Codey by default. Remove it, click
**+ add**, and pick **CyberPi** from the device library.

**3. Connect.** Click **Connect**, then confirm in the dialog that appears. If mBlock offers a
firmware update, take it — several of the later steps depend on a current CyberOS.

**4. Switch to Python.** Toggle the editor from Blocks to **Python**.

**5. Switch to Upload mode.** This is the step people miss, and it changes what your program
actually is:

| | Live mode | Upload mode |
| --- | --- | --- |
| Where the code runs | your computer, driving the board over USB | on the CyberPi itself |
| Language | full Python 3, third-party libraries allowed | MicroPython only |
| Unplug the cable | program stops | program keeps running |
| Button | Run | **Upload** |

Every step in this directory must run in **Upload mode**. Live mode drives the board remotely
through a serial protocol, so it would be measuring your Mac's audio and network stack, not the
robot's — which is the entire question we are trying to answer.

If mBlock warns you when switching, accept it.

## Running step 1

1. Open `apps/cyberpi/steps/step01_hello.py` and copy the whole file.
2. Paste it into the mBlock Python editor, replacing whatever is there.
3. Pick a program slot. **Uploading overwrites whatever is in the slot you choose**, so pick an
   empty one, or one holding a demo you do not mind losing. Left alone, an upload lands in
   Program 1 under the name `main` — see [naming](#naming-programs-and-the-chinese-characters-in-my-programs).
4. Click **Upload** and wait. The first upload of a session takes longer than later ones.

### What you should see

- the screen clears and shows `Rocky step 1`
- the five LEDs go green
- `tick 1` … `tick 5`, one per second, on the screen and in the terminal panel
- `PASS - toolchain works`, and the LEDs turn blue

If you get all of that, the toolchain works and steps 2 and 3 need nothing further from you.

### Where the printed output goes

Screen text comes from `cyberpi.console.println()`. The `print()` lines go over USB to mBlock's
terminal/console panel, so keep the cable attached to read them. Later steps print far more than
they display — the CyberPi screen is 128×128 and cannot show a module list — so get comfortable
finding that panel now.

## Naming programs, and the Chinese characters in My Programs

Three things about the My Programs list, from Makeblock's own docs:

- An uploaded program is named **`main`** by default, and overwrites **Program 1** unless you pick
  another slot at upload time.
- The name comes from the **project name in the editor**, so you rename the project *before*
  uploading. There is no way to rename a slot from the device afterwards.
- Makeblock's help centre is widely quoted as saying names can only be set in the mBlock 5 **web**
  version. **Treat that as unconfirmed.** Someone working in the web editor could not find any such
  control, and nobody here has managed to read the source article — it is behind a 403 from this
  environment.

If you want a named slot, the thing to try is signing in to a Makeblock account, naming and saving
the project, and *then* uploading — a project may have no persistent name until it is saved, which
would explain both the "web only" framing and the missing control. Unverified.

Do not spend long on this. The slot name has no effect on steps 1–12, and only starts to matter at
the very end of Stage 1, when Rocky is packaged into a slot a person picks from a menu.

### If slots show Chinese characters

The documented default is `main`, so Chinese names mean something else is going on. Two likely
causes, in order:

1. **They are untouched factory demos.** CyberPi ships with demo programs whose names render in
   Chinese on some firmware builds. If the Chinese entries are slots you never uploaded to, that is
   all this is — overwrite them or leave them alone.
2. **mBlock's UI language is set to Chinese**, so a new project's default name is a Chinese string
   such as 未命名 ("unnamed"), and that gets sent as the program name. Set mBlock's language to
   English and start a fresh project.

Cause 2 is a hypothesis rather than something confirmed against Makeblock's documentation — check
it first because it is quick, but do not be surprised if the answer turns out to be cause 1.

This matters more later than it does now. Stage 1's final item is packaging Rocky into a program
slot such that exiting returns you to ordinary CyberOS, and that only works cleanly if the slots
are legible.

## Getting your board back to normal

Your uploaded program runs on boot, which will feel alarming the first time. It is not permanent:

1. Press the **home** button to return to the CyberOS home screen.
2. Move the joystick up or down to highlight **Switch Program**, and press **B**.
3. Pick a different program and press **B**. The CyberPi restarts into it.

The board's own firmware is untouched by anything in this directory. Only Stage 2 would replace
it, and that is a decision the steps have not reached yet.

## When it does not work

| What you see | Likely cause |
| --- | --- |
| No device in the connect list | charge-only USB cable, or the board is switched off |
| Connect fails or the port is busy | another mBlock window, or a serial monitor, is holding the port |
| Upload button greyed out | still in Live mode, or no device connected |
| Upload succeeds, nothing happens | the program went to a different slot than the one running — use Switch Program |
| Screen blank but LEDs work | `cyberpi.console` output can be pushed off-screen; power-cycle and watch from the start |
| `AttributeError: get_shield` | a known bug in the PyPI `cyberpi` 0.0.7 package used by **Live** mode. Upload mode does not use it — another reason to stay in Upload mode |

If step 1 misbehaves and you want to rule out the file itself, this is the irreducible version:

```python
import cyberpi
cyberpi.console.println("hi")
cyberpi.led.on(0, 60, 0)
```

Three lines. If that shows nothing, the problem is the connection or the mode, not the code.

## Then what

Record the outcome in [`../STEPS.md`](../STEPS.md) and move to step 2 (speaker) and step 3
(microphone). Both need only the board and this same setup.

Step 5 is where it gets interesting: that is the one that goes looking for a raw audio path and
starts actually answering the Stage-1 question.
