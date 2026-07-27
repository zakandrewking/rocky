# Upstream sources: what Makeblock publishes, and what it does not

Checked before continuing to reverse-engineer the firmware, because reading the source is faster
than guessing at it. Result: **partially useful.** The hardware layer is open; the layer we are
actually probing is not.

## Open, and useful

### `Makeblock-official/CyberPi-Library-for-Arduino` — GPL-3.0

The Arduino/PlatformIO library for the same board. `lib/cyberpi/src/` contains:

| Path | What is in it |
| --- | --- |
| `microphone/es8218e.c`, `es8218e.h` | **the audio codec driver** |
| `sound/synth.h`, `tables.h` | tone synthesis |
| `lcd/`, `gyro/`, `io/`, `i2c/` | the rest of the board |

**The CyberPi's audio codec is an Everest Semiconductor ES8218E**, on I2C address `0x10`
(`ES8218E_ADDR`, with `0x11` when CE=1). The header carries the full register map — reset, six
clock-manager registers, the serial data port, seven system-control registers, twenty-plus ADC
control registers, and MCLK divider enums.

That is the single most valuable thing found here, and it is squarely Stage-2 material: it names
the chip, gives its register map, and shows how Makeblock configures it. If we ever write native
firmware, this is the reference for bringing up audio.

**Licence caveat:** GPL-3.0. Reading it to learn hardware facts — which chip, which I2C address,
which registers — is fine. Shipping code derived from it inside Rocky's firmware would attach
GPL-3 obligations to that firmware. Decide that deliberately, not by copy-paste.

### `Makeblock-official/micropython-api-doc`

Generates <https://makeblock-micropython-api.readthedocs.io>. Its `docs/` tree covers
**codey&rocky, haloboard, novapi**, plus generic MicroPython library and reference material.

**There is no `cyberpi` directory.** The CyberPi is not documented here at all.

## Not open

**The CyberOS MicroPython firmware.** This is where `cyberpi.mic_o`, the `i2s_mic` type, and
`get_recording_data()` live — the exact things steps 5c–5f are working out. It is not published in
the Makeblock GitHub organisation, and MicroPython's MIT licence creates no obligation to publish
it. The board reports `MicroPython 44.01.008-16-g7e26a976-dirty`, a private build.

So the semantics we still want — what the second element of `get_recording_data()`'s list means,
what its argument does, whether repeated calls advance — cannot be read off any published source.
Hardware probing stays the only route.

Similarly not published: the `cyberpi` Python package on PyPI (`makeblock` 0.1.8) is generated
online-mode glue, not the firmware, which is exactly why it turned out to be a *subset* of what the
board really exposes.

## Practice

Check for published source **before** probing, not after. Three cheap lookups, in order:

1. the vendor's GitHub organisation — `github.com/<vendor>` and its repository list
2. any docs site's backing repository — ReadTheDocs projects almost always have one, and the raw
   `.rst` is more complete and more searchable than the rendered page
3. the package registries — but treat generated packages as a lower tier of evidence than
   firmware source or a `dir()` on real hardware, since this project already got burned by one

In this environment, `raw.githubusercontent.com` and `github.com` are reachable; `codeload`
tarball downloads return 403, and most vendor documentation hosts (`support.makeblock.com`,
`education.makeblock.com`, `forum.makeblock.com`) are blocked or unresolvable. Fetch individual
raw files rather than trying to clone.
