"""Step 5i - does the buffer FILL progressively while recording?

Step 5g asked whether the buffer grows and got a flat answer: a constant
160,000 bytes during recording, then 49,664 after stop. 160,000 / 16,000 B/s is
a preallocated **10-second** buffer, and the reported length simply does not
track progress.

But length is not the same question as content. If the driver is writing
samples into that buffer as they arrive, then at t+1s the first ~16,000 bytes
hold audio and the rest is untouched. Finding that boundary - the fill frontier
- and watching it advance would let Rocky build its own cursor and stream audio
out while the person is still talking. That is worth knowing before settling
for fixed turns.

WHY THIS DOES NOT LOOK FOR SILENCE
  An obvious approach is "find the last non-zero byte". It is wrong twice over:
  8-bit unsigned PCM sits at 0x80 when silent, not 0x00, and nobody talks
  continuously for the whole take anyway.

  Instead this compares the buffer against *itself* over time. Even a silent
  microphone produces dither and noise, so a region being written changes
  between polls, and a region not yet written does not. That works whether or
  not you are talking.

MEMORY
  The buffer is 160 KB and free heap is about 1.27 MB, so whole-buffer
  snapshots would be tight. This samples ~120 evenly spaced probe points
  instead, which locates the frontier to within a percent of the buffer and
  costs a rounding error of RAM.

STILL: MAKE CONTINUOUS NOISE
  Talk, hum, or tap the desk for the whole recording. It is not required for
  the comparison to work, but it makes the result far easier to read.
"""

import time

import cyberpi

POLL_MS = 300
POLL_COUNT = 8
PROBE_POINTS = 120
BYTES_PER_SECOND = 16000  # measured in step 5f


def payload_of(result):
    """get_recording_data returns [header, data]; return the larger element."""
    best = None
    try:
        for index in range(len(result)):
            item = result[index]
            try:
                size = len(item)
            except Exception:
                continue
            if best is None or size > len(best):
                best = item
    except Exception:
        return None
    return best


def sample_points(data, count):
    """Values at evenly spaced offsets - cheap stand-in for a full snapshot."""
    size = len(data)
    step = max(1, size // count)
    points = []
    offset = 0
    while offset < size and len(points) < count:
        value = data[offset]
        points.append(value if isinstance(value, int) else ord(value))
        offset += step
    return points, step


cyberpi.console.clear()
cyberpi.console.println("5i: fill frontier")
print("")
print("=== ROCKY STEP 5I: FILL FRONTIER ===")

mic = cyberpi.mic_o

print("")
print("--- recording; polling every " + str(POLL_MS) + " ms ---")
print("  expect the frontier to advance ~" + str(int(BYTES_PER_SECOND * POLL_MS / 1000)) + " bytes per poll")
cyberpi.console.println("MAKE NOISE")
cyberpi.console.println("the whole time!")
cyberpi.led.on(60, 0, 0)

baseline = None
step_size = 0
previous = None
frontiers = []

try:
    mic.record_start()

    for index in range(POLL_COUNT):
        time.sleep(POLL_MS / 1000.0)
        try:
            data = payload_of(mic.get_recording_data(0))
            if data is None:
                print("  poll " + str(index + 1) + ": no payload")
                continue

            points, step_size = sample_points(data, PROBE_POINTS)

            if baseline is None:
                baseline = points
                previous = points
                print("  poll 1: baseline captured, " + str(len(points)) + " points, step " + str(step_size))
                continue

            # Last probe point that changed since the first poll: everything
            # up to here has been written to.
            last_changed_since_start = -1
            last_changed_since_previous = -1
            for position in range(min(len(points), len(baseline))):
                if points[position] != baseline[position]:
                    last_changed_since_start = position
                if previous is not None and position < len(previous) and points[position] != previous[position]:
                    last_changed_since_previous = position

            frontier_bytes = (last_changed_since_start + 1) * step_size if last_changed_since_start >= 0 else 0
            frontiers.append(frontier_bytes)
            print(
                "  t+"
                + str((index + 1) * POLL_MS)
                + "ms: frontier ~"
                + str(frontier_bytes)
                + " B ("
                + str(round(frontier_bytes / float(BYTES_PER_SECOND), 2))
                + " s), changed-since-last idx "
                + str(last_changed_since_previous)
            )
            previous = points
        except Exception as exc:
            print("  poll " + str(index + 1) + " failed: " + type(exc).__name__ + ": " + str(exc))

    mic.record_stop()
except Exception as exc:
    print("  failed: " + type(exc).__name__ + ": " + str(exc))
cyberpi.led.off()

# --- what actually happened ------------------------------------------------
print("")
advancing = len(frontiers) >= 3 and frontiers[-1] > frontiers[0]
if advancing:
    print("*** FRONTIER ADVANCED - the buffer fills progressively ***")
    print("    frontiers: " + str(frontiers))
    print("    Rocky can slice the buffer by elapsed time and stream.")
    cyberpi.console.println("PROGRESSIVE!")
elif frontiers and max(frontiers) > 0:
    print("buffer changes, but the frontier did not advance steadily:")
    print("    " + str(frontiers))
    print("    could be whole-buffer rewrites, or noise across the entire buffer")
    cyberpi.console.println("unclear")
else:
    print("no change detected: the buffer is not visibly written during recording")
    print("    fixed turns it is - record, stop, read, send")
    cyberpi.console.println("fixed turns")

# --- and confirm the final length, as a sanity check -----------------------
try:
    time.sleep(0.3)
    final = payload_of(mic.get_recording_data(0))
    size = len(final) if final is not None else -1
    print("")
    print("final length after stop: " + str(size) + " bytes = " + str(round(size / float(BYTES_PER_SECOND), 2)) + " s")
except Exception as exc:
    print("final read failed: " + str(exc))

print("")
print("=== END STEP 5I ===")
