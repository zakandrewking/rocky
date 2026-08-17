# Rocky's robot agent: the one payload that runs on the board.
#
# Pushed with `pnpm robot:push <board-ip> apps/robot/device/rocky_agent.py`, into a bootstrap.py
# that is already running (see its header). There is no other agent -- the older commanded-motion
# one is frozen at deprecated/motion_agent.py and is not pushed by anything.
#
# This is a body that moves on its own and that Rocky *collaborates with*, rather than one she
# drives. She can see what it has been doing, change how wound up it is, ask it for a gesture, and
# stop it -- and those last three are intentions, not commands: the loop honours them at its own
# natural seams. "Stop" is the single real imperative.
#
# This is step16_loudness_drive_sticky.py
# (v11 of the loudness-driving experiment) with an observation layer added -- the motion loop and
# every tuned constant below are byte-identical to that file, which stays in steps/ as both the
# tuning record and the rollback if this one misbehaves. scripts/check-behavior-parity.mjs fails
# the build if they ever drift.
#
# PHASE A of letting the voice character collaborate with this loop: observation only. The board
# streams what it *did* to whoever is listening; nothing can steer it yet. That direction is
# deliberate. The motion loop decides at ~20Hz and its reactions last 0.3-4s, while the voice
# character cannot produce a spoken word in under about two seconds -- so "what are you doing
# right now" is always a stale question by the time it is answered. What travels well across that
# gap is recent history: "4 seconds ago something very loud startled me, I ran for two seconds,
# I have been listening since." That is a true sentence whenever it arrives.
#
# Later phases (see TODOS.md) add the other direction as *intentions* rather than commands --
# queued gestures consumed at this loop's natural seams, mood as multipliers over the constants
# below, and one real imperative (stop). Nothing in this file's tuning changes for any of that.
#
# --------------------------------------------------------------------------------------------
# ORIGINAL step16 HEADER FOLLOWS
# --------------------------------------------------------------------------------------------
# Pushed into bootstrap.py as a payload. v11 of the loudness-driving experiment -- a real
# architecture change from v9/v10 (step14/step15), not just a tuning pass.
#
# Live UX direction (2026-08-08): while stopped, a single clean mic reading is trustworthy (no
# self-noise at all, motors are off) -- so treat that one good reading as decisive ("sticky"):
# commit to a sustained drive at the level it implies.
#
# Correction after live testing: committing and then going fully deaf until the sustain window
# ends meant a louder sound *while already driving* (e.g. starting soft then raising your voice)
# had no way to register until the current commitment happened to expire. Fixed by reading the
# mic during "driving" too, using the measured per-RPM SELF_NOISE table to tell "louder than my
# own motor" from "just my own motor" -- but only to ESCALATE: a reading that maps to a higher
# CURVE level than the current commitment bumps rpm up (and refreshes the sustain timer) right
# away, while a quieter-or-equal reading is ignored so the commitment still holds steady rather
# than decaying or jittering. This is a narrower, safer use of self-noise subtraction than v9's
# (step14) full continuous control loop: an approximation error here just shifts when an
# escalation fires, not the moment-to-moment speed itself.
#
# This does NOT reintroduce v1-v7's "stutter step." The difference is frequency and cause: v7
# forced a stop every ~700ms purely to sample, regardless of what was happening -- a mechanical,
# rhythmic hiccup. Here, a stop only happens at the natural end of a multi-second commitment (or
# after a turn/startle reaction), so pauses are infrequent and read as "taking a breath to listen
# again," not a hiccup while trying to move. Within a commitment, the motors run continuously
# every tick with no forced interruption -- see step14/step15's history for why continuous
# driving (vs. v4/v7/v8's per-cycle alternation) was the first fix for "little bursts."
#
# Behavior, mapped onto the existing measured pieces:
#   - Quiet -> stays still (a "listening" mode where rpm is always 0).
#   - One qualifying reading while listening -> commit: drive continuously at that level for a
#     sustain window sized by how loud it was (louder = longer, see SUSTAIN_* below), satisfying
#     both "quiet talk drives slowly for a few seconds" and "a scream should reach and hold max
#     speed" from docs/loudness-drive-problem-statement.md's original expected-usage section.
#   - A commitment that's been driving continuously for DRIVE_TIMEOUT_MS (~8s) gets interrupted
#     by a stop + ~180 degree turn, so sustained loud input doesn't just drive off in one
#     direction forever -- then goes back to listening, so if the sound is still going it can
#     commit again facing a new direction.
#   - A sudden, very loud spike while listening (not a scream that built up gradually) looks
#     startled: a quick reverse jolt ("jump" -- the mBot2 has no legs, so this is the closest
#     physical analog) then a few seconds retreating ("runs away").
#   - Two more idle-only triggers, added per live feedback asking for something like touch
#     detection: the floor sensor (quad_rgb_sensor) suddenly deviating from its own recent
#     baseline reads as a physical bump -- reacts with its own "dizzy" spin-and-silly-face, a
#     distinct reaction from being startled by sound, since getting bumped and hearing a scream
#     aren't the same feeling. The ultrasonic sensor reporting something newly within APPROACH_CM
#     while sitting still reads as "something just got close to me" and reuses the sound-startled
#     flee reaction instead (that one's closer to a real threat than a bump is).
#
# What's measured vs. guessed (same discipline as every prior version): CURVE is still from the
# real 2026-08-08 calibration run. SUSTAIN_MIN/MAX_MS, DRIVE_TIMEOUT_MS, TURN_RPM/TURN_MS, and the
# startle thresholds are NOT measured -- flagged exactly like v1-v7's window sizes were, meant to
# be tuned against live telemetry.
#
# Further live correction: the ability to react to something louder than expected was, at first,
# only wired into "driving." Any state that runs the motors -- turning, the startled jump/flee,
# the post-flee recovery wobble -- now runs the same self-noise-subtracted check every tick
# (see _sensed_level/_start_driving) using whatever RPM magnitude that state currently commands,
# and abandons its scripted action to start driving forward if something genuinely louder
# registers. "settling" is the one deliberate exception: motors have JUST been commanded to stop
# and mechanical ringing hasn't died down yet -- that untrustworthy window is exactly what
# SETTLE_MS exists to wait out, so it doesn't get a mic check of its own.

import cyberpi
import mbot2
import utime

try:
    import ujson
except ImportError:
    import json as ujson

try:
    import usocket as socket
except ImportError:
    import socket

# Same defensive pattern device/rocky_agent.py already established for this hardware: a base
# mBot2 kit may not have the ultrasonic accessory attached, so don't assume it's there. Same for
# the quad_rgb_sensor (floor/line sensor) below -- separate try/except since kits could plausibly
# have one accessory but not the other.
try:
    from mbuild import ultrasonic2

    HAS_ULTRASONIC = True
except ImportError:
    HAS_ULTRASONIC = False

try:
    from mbuild import quad_rgb_sensor  # confirmed real import: device/rocky_agent.py already
    # uses this same one, though for get_all_data() instead of the get_reflect() it assumed --
    # see _reflect_readings() for how that got sorted out live, on real hardware.
    HAS_LINE_SENSOR = True
except ImportError:
    HAS_LINE_SENSOR = False


def _distance_cm():
    if not HAS_ULTRASONIC:
        return -1
    return ultrasonic2.get_distance()


def _reflect_readings():
    """The 4 per-channel intensity readings from the quad_rgb_sensor -- "quad" is literal, 4
    channels, not 2. get_reflect() doesn't exist on this firmware despite being in the generated
    `makeblock` package (mbuild-api-surface.md's weak-tier caveat proved out); confirmed live via
    dir() + probing candidate calls (2026-08-08): get_intensity(1) returned the same value as
    get_all_data()[0], so get_all_data()'s first 4 elements are the real per-channel readings."""
    if not HAS_LINE_SENSOR:
        return None
    try:
        return tuple(quad_rgb_sensor.get_all_data()[0:4])
    except Exception as error:
        _report_error_once("line_sensor_error", error)  # surfaced instead of silently swallowed
        return None

# ============================== CALIBRATED CONSTANTS (measured) ==============================
# Live feedback: the original (3,0)->(6,0.35) jump was too coarse -- almost all of a real "talk"
# phase's dynamic range (measured 0-18 above floor) fell inside that single 3-unit step, so soft
# vs. louder talking barely differed in speed. Two extra anchors (12, 25) spread resolution across
# that same measured range instead of jumping straight to "moderately fast." Top anchor lowered
# twice per live feedback ("increase sensitivity for getting to max speed", then "further increase
# sensitivity") from a measured 80 down to 50 then 32 -- a product choice about how easy max speed
# should be to reach, no longer the raw measured loud-talking level. The (3,0) floor-jitter anchor
# is left alone throughout -- that one's about the sensor's own noise floor, not voice sensitivity.
CURVE = ((3.0, 0.0), (5.0, 0.15), (9.0, 0.35), (18.0, 0.6), (27.0, 0.85), (32.0, 1.0))
SELF_NOISE = ((0.0, 0.0), (20.0, 42.0), (40.0, 65.0), (60.0, 83.0))  # used during any
# motors-on state (see header) to detect a louder-than-expected sound; NOT used in "listening",
# where motors are already off and subtraction isn't needed. Caveat carried from v10: measured
# while spinning in place (step12), reused here as an approximation for straight driving too.
SETTLE_MS = 180  # measured motor-stop ring-down (step12); the pause before any clean read
# ==============================================================================================

# ============================== GUESSED CONSTANTS (untested -- tune live) ====================
SUSTAIN_MIN_MS = 1200  # a bare-qualifying quiet reading sustains this long -- lowered from an
# initial 3000 per live feedback ("faster"): the dominant source of felt latency in this design
# is how long a commitment holds before the next clean listen, not per-tick smoothing (there is
# none -- see header, this design holds a single locked-in reading rather than reacting per tick).
SUSTAIN_MAX_MS = 9000  # a max-level reading would sustain this long, but DRIVE_TIMEOUT_MS below
# is deliberately smaller, so a max-level commitment always gets interrupted by a turn instead of
# quietly completing its own sustain window.
DRIVE_TIMEOUT_MS = 8000
TURN_RPM = 105  # scaled with MAX_RPM below, now grounded in the mBot2's real rated speed
TURN_MS = 1100  # paired guess with TURN_RPM for "about 180 degrees" -- no deg/s data exists yet
OBSTACLE_TURN_MS = int(TURN_MS * 110 / 180)  # ~110 degrees instead of the personality turn's
# ~180 -- same guessed degrees-per-ms ratio as TURN_MS, just scaled for a smaller angle

# THE dial for "startle and flee" vs. "just drive forward fast": a clean (motors-off) reading at
# or above STARTLE_CUTOFF is a candidate flee trigger; below it, the same loudness just drives
# forward per CURVE (whose own top anchor sits comfortably under this). Raise this to make the
# robot harder to startle, lower it to make it jumpier.
STARTLE_CUTOFF = 85.0
# Secondary refinement, not the main dial above: the reading must ALSO have jumped at least this
# far above the recent baseline, so a scream that gradually climbs past STARTLE_CUTOFF drives
# fast (as intended) instead of "fleeing" every time it's simply loud. Without this, sustained
# loud screaming would trigger flee repeatedly rather than the fast-forward behavior it should.
STARTLE_JUMP_THRESHOLD = 55.0
BASELINE_ALPHA = 0.03  # how fast the recent-baseline estimate tracks ambient loudness
JUMP_RPM = 165  # the fastest speed in the whole file -- a startled flinch should feel more
# urgent than an ordinary max-speed cruise, not slower than one. Set relative to the real 178 RPM
# rated-load ceiling (see MAX_RPM below) rather than scaled off the old MAX_RPM=60/100 guesses.
JUMP_MS = 300  # the startled "flinch" -- reverse hard, briefly, fixed duration regardless of how
# loud the trigger was (a flinch reads as reflexive, not proportional)
FLEE_RPM = 140  # fast and sustained, just under MAX_RPM -- urgent but not as sharp as the jolt
SENSOR_MAX = 100.0  # measured: real calibration readings (loud/scream bursts) topped out here
FLEE_MS_MIN = 1500  # how long the retreat lasts scales with how startling the sound was: a
FLEE_MS_MAX = 4000  # reading right at the threshold flees briefly, one at the sensor's ceiling
# flees for much longer -- "the louder the surprise, the farther it drives without slowing down."
# Speed (FLEE_RPM) stays constant either way; only distance/duration scales.

WOBBLE_RPM = 45  # a quick glance, gentler than a real TURN_RPM turn
# After fleeing, spin back around to face the direction it just ran toward (so it isn't left
# facing backward), then a few decaying alternating glances -- "did something just happen?"
# before settling back into listening. (duration_ms, spin_rpm, face_label, led_color); spin_rpm
# feeds both wheels the same signed value (drive_speed(rpm, rpm) spins in place), so its sign
# picks direction and magnitude picks speed.
RECOVER_SCHEDULE = (
    (TURN_MS, TURN_RPM, "O   O", (255, 200, 120)),  # the real ~180 -- now facing where it fled
    (220, WOBBLE_RPM, "o     .", (255, 230, 160)),  # glance right
    (220, -WOBBLE_RPM, ".     o", (255, 230, 160)),  # glance left
    (160, WOBBLE_RPM, "o     .", (255, 230, 160)),
    (160, -WOBBLE_RPM, ".     o", (255, 230, 160)),
    (120, WOBBLE_RPM, "o     .", (255, 230, 160)),  # settle, still a little rattled
)

DIZZY_RPM = 70  # a comedic, sustained spin -- being bumped reads as "whoa, dizzy," not "scared"
DIZZY_MS = 1800  # long enough for a couple of full rotations at DIZZY_RPM, not just one turn
DIZZY_FACE = ("@ @", (170, 255, 130))  # label, LED color -- distinct from every other reaction
# ==============================================================================================

# ============================== PHASE A: OBSERVATION (not tuning) ============================
# None of this affects motion. It is additive: one append per state transition, plus a socket
# pumped once per tick. Kept cheap on purpose -- this loop's sampling *is* its pipeline (one
# get_loudness() per tick, no smoothing, startle is an edge trigger with no hysteresis), so
# anything that slows the tick degrades startle detection without changing a single constant.
# Found live the first time this ran (2026-08-15): the robot span on the spot indefinitely,
# listening -> dizzy -> settling -> listening -> dizzy, about every 2.5s. Two causes, both fixed
# here rather than by moving BUMP_THRESHOLD, which would only have traded this for a deaf sensor:
#   1. After a spin the robot is over a different patch of floor, so the old per-channel baseline
#      describes somewhere it no longer is. The baseline is re-seeded on every return to
#      listening now (see _enter), instead of being eased toward the new floor at
#      REFLECT_BASELINE_ALPHA -- which could never converge, because listening only lasted a few
#      ticks before the deviation re-triggered.
#   2. Even so, nothing bounded the reaction. Repeated spinning reads as a fault rather than a
#      personality, so it may now happen twice before the bump sense goes quiet for a while.
DIZZY_MAX_CONSECUTIVE = 2
DIZZY_COOLDOWN_MS = 20000  # bump detection off for this long once the limit is hit
DIZZY_STREAK_RESET_MS = 30000  # a bump this long after the last one starts a fresh streak

EVENT_PORT = 8768  # separate from rocky_agent's 8765 (motion) and 8766 (OTA) so both can exist
EVENT_BEACON_PORT = 41900  # same port rocky_agent beacons on, but a different service name, so
EVENT_SERVICE = "rocky-behavior"  # the app's existing robot discovery ignores it rather than
# connecting to a motion agent that is not running.
EVENT_BEACON_INTERVAL_MS = 1000
SNAPSHOT_INTERVAL_MS = 500  # so a client that connects mid-flee still learns the current mode
EVENT_HISTORY = 24  # ring buffer size; transitions are seconds apart, so this is minutes of it
# ==============================================================================================

LAPTOP_HOST = "192.168.1.138"  # this Mac's current LAN IP -- check `ipconfig getifaddr en0`
LAPTOP_PORT = 8767

# Makeblock's own published spec for the mBot2's 180 Optical Encoder Motor
# (makeblock.com/products/180-optical-encoder-motor-for-mbot2): rated load speed 178 RPM +-10%,
# no-load 350 RPM. 150 sits comfortably under the rated figure (margin for real load/battery
# sag) while being real headroom above the earlier unverified 60/100 guesses. Real cm/s at this
# RPM is still unmeasured (STEPS.md step 9 is still open) -- this bounds the dial, not the feel.
MAX_RPM = 150
MIN_RPM = 10  # below this the encoder motors whine without really moving
MIN_LEVEL = 0.05  # minimum CURVE level while listening that counts as "a clear reading"

# Basic collision avoidance: same value device/rocky_agent.py already uses for this same sensor
# and hardware (see PLAN.md's "AI goals x mBot2 Shield obstacle avoidance"). Checked every tick
# while driving forward, taking priority over everything else -- an obstacle is a hard safety
# override, not a loudness consideration. Only covers "driving" (translating forward): the mBot2
# has a single fixed, forward-facing ultrasonic sensor (PLAN.md), so there's no way to see what's
# behind it during the startled flee's backward retreat -- a real hardware limit, not an
# oversight. Reacts by stopping and turning -- shares "turning" mode's machinery with the
# personality 8s-timeout turn, but with its own angle and a randomized direction (see
# OBSTACLE_TURN_MS/_random_sign and _tick_driving), not the timeout turn's fixed ~180.
OBSTACLE_STOP_CM = 15

# "Did something touch/approach me while idle?" -- both checked only in "listening" (motors off,
# so neither sensor is confused by the robot's own vibration/motion). Neither has a dedicated
# calibration pass (unlike CURVE/SELF_NOISE), so these thresholds are first guesses, meant to be
# tuned against live telemetry same as every other guessed constant in this file.
BUMP_THRESHOLD = 30  # a real quiet-room baseline reading was ~42-51 per channel (see
# _reflect_readings' header for how that got confirmed); how far a channel must suddenly jump
# from its own recent baseline to count as a physical bump, not ordinary floor-color drift
REFLECT_BASELINE_ALPHA = 0.05
APPROACH_CM = 10  # tighter than OBSTACLE_STOP_CM (15) on purpose -- that one's "stay safe while
# driving," this one's "something is right in front of me while I'm sitting still." Edge-detected
# (newly close, not merely close) so parking near a wall doesn't startle it forever.

FLOOR_SEED_SAMPLES = 8
FLOOR_SEED_INTERVAL_MS = 25

# level threshold, face key, label, LED color -- highest threshold <= level wins (entries must
# stay in ascending-threshold order -- see _face_for_level), set once at commit time (not
# re-evaluated per tick -- there's nothing to react to mid-commitment). idle/listening/happy are
# device/rocky_agent.py's existing face vocabulary; "alert" and "maxed" are new here.
FACES = (
    (0.0, "idle", ". _ .", (40, 40, 60)),
    (0.15, "listening", "o _ o", (0, 150, 255)),
    (0.5, "alert", "> < ", (255, 150, 0)),
    (0.85, "happy", "^ _ ^", (255, 30, 130)),
    (0.95, "maxed", "X   X", (255, 0, 90)),  # "X eyes" at/near max speed, per live feedback
)

# The robot wakes physically still. DEFAULT_MOOD is the ordinary awake/fallback disposition;
# BOOT_MOOD is deliberately separate so a reboot can never silently re-arm the motors, and the
# excitement decay target is separate again so cooling down cannot accidentally mean going inert.
DEFAULT_MOOD = "exploring"
BOOT_MOOD = "still"
EXCITABLE_DECAY_MOOD = "calm"

_state = {
    "booted": False,
    "floor": None,
    # "listening" | "driving" | "settling" | "turning" | "startled" | "recovering" | "dizzy"
    "mode": "listening",
    "mode_start": 0,
    "return_to": "listening",  # where "settling" goes next
    "level": 0.0,
    "rpm": 0,
    "sustain_ms": 0,
    "drive_started": None,  # start of the current unbroken run of commitments, for the 8s cap
    "turn_ms": TURN_MS,  # how long "turning" spins for -- parameterized so the personality
    "turn_rpm": TURN_RPM,  # 8s-timeout turn and the collision-avoidance turn can differ
    "turn_reason": "",  # carried through "settling" so the eventual "turning" transition can say
    # why it is turning; the two turns look identical on the wire otherwise
    "baseline": 0.0,
    "flee_ms": FLEE_MS_MIN,
    "recover_index": 0,
    "recover_seg_start": 0,
    "reflect_baseline": [None, None, None, None],  # seeded per-channel, see _tick_listening
    "was_close": False,  # edge-detector for "something newly came close" -- see APPROACH_CM
    "reported_errors": [],  # event keys already sent via _report_error_once, so it fires once
    "sock": None,
    "sock_tried": False,
    # Phase A observation, all additive:
    "events": [],  # ring of (ticks_ms, mode, detail) appended in _enter, newest last
    "evt_server": None,
    "evt_conn": None,
    "evt_beacon": None,
    "evt_last_beacon": 0,
    "evt_last_retry": 0,
    "evt_last_snapshot": 0,
    "evt_buffer": "",
    # Phase B/C: what the voice character has asked for. Advisory -- the motion loop decides when
    # (and whether) to honour it. "stop" is the one exception and applies immediately.
    "dizzy_streak": 0,
    "dizzy_last_at": 0,
    "bump_suppressed_until": 0,
    "mood": BOOT_MOOD,
    "mood_since": 0,
    "gesture": None,  # (name, expires_at_ticks) or None
    "gesture_repeats": 0,  # how many more times to do it once the current one finishes
    "gesture_name": "",
    "gesture_id": "",  # the caller's own id for this intention, echoed back so it can follow
    # what became of it instead of guessing from timing
}


# =========================== PHASE A-C: TALKING TO THE VOICE CHARACTER =======================
# Out: what just happened, as history. In: what the character would like to happen, as intentions.
# Everything here is wrapped so an observation failure can never take the motion loop down with
# it -- a dropped socket must cost visibility, never driving.

# Awake moods scale the tuned constants at their point of use; they never rewrite them. "still"
# is stronger: tick() treats it as a hard motor interlock and does not run a sensor/state handler.
# That keeps every value above the source of truth and every nudge reversible.
#   startle: multiplies STARTLE_CUTOFF -- higher is harder to startle
#   speed:   multiplies the committed rpm -- 0.0 means "listen but never drive"
MOODS = {
    # The resting disposition: awake, restless, happy to wander toward whatever it hears. Named
    # "exploring" rather than "normal" because it is not a neutral -- it is the one that makes the
    # robot go looking, and it is what "come over here" resolves to. It cannot steer, but it can
    # become the kind of thing that rolls toward a voice.
    "exploring": {"startle": 1.0, "speed": 1.0},
    "calm": {"startle": 1.4, "speed": 0.7},
    "excitable": {"startle": 0.7, "speed": 1.0},
    "still": {"startle": 1.4, "speed": 0.0},
}
# Excitement burns off. Every other disposition is a standing decision -- "settle down" and "keep
# still" are things a person asked for and should not quietly undo themselves -- but being wound up
# is a state you come down from into calm, and left alone it never did: one "ooh, fun!" early in a session
# silently lowered the startle threshold by 30% for the next twenty minutes. GUESSED, like every
# other timing in this file: tune it against how long a burst of play actually feels.
EXCITABLE_COOLDOWN_MS = 45000
GESTURES = ("spin", "wiggle")
MAX_GESTURE_REPEATS = 10  # "spin ten times" should work; beyond that it stops being playful
GESTURE_SPIN_MS = TURN_MS * 2  # TURN_MS is the tuned ~180 degrees, so a full turn is two of them
GESTURE_TTL_MS = 6000  # an intention the loop never got a safe moment to honour expires rather
# than firing minutes later, long after the moment that prompted it has passed


def _mood():
    return MOODS.get(_state["mood"], MOODS[DEFAULT_MOOD])


def _hold_still(now, detail="still interlock"):
    """Hard movement interlock: stop now and bypass every sensor-driven state handler.

    This is intentionally centralized rather than repeated in loudness, floor, and proximity
    checks. It also catches an already-running drive, turn, jump, recovery, or gesture on the same
    tick that Rocky goes still. Reasserting zero speed every tick makes the invariant physical,
    not merely a state-machine convention.
    """
    had_queued_gesture = _state["gesture"] is not None or _state["gesture_repeats"] > 0
    mbot2.drive_speed(0, 0)
    _state["gesture"] = None
    _state["gesture_repeats"] = 0
    _state["level"] = 0.0
    _state["rpm"] = 0
    _state["drive_started"] = None
    _state["return_to"] = "listening"
    if _state["mode"] != "listening" or had_queued_gesture:
        _enter("listening", now, detail)
        _show_face("o _ o", (0, 150, 255))
    _send_telemetry(',"interlock":"still"')


def _decay_mood(now):
    """Lets excitement burn off on its own. Only excitement: the others are standing requests."""
    if _state["mood"] != "excitable":
        return
    if utime.ticks_diff(now, _state["mood_since"]) < EXCITABLE_COOLDOWN_MS:
        return
    _state["mood"] = EXCITABLE_DECAY_MOOD
    _state["mood_since"] = now
    # No behaviour transition: coming down off a burst of excitement is not an incident Rocky
    # should narrate. Raw telemetry records the lifecycle and the 500ms snapshot carries the new
    # disposition to the phone.
    _send_telemetry(',"event":"mood_decayed"')


def _emit(payload):
    """Best-effort line to the connected observer. Never raises into the motion loop."""
    conn = _state["evt_conn"]
    if conn is None:
        return
    try:
        conn.send((ujson.dumps(payload) + "\n").encode())
    except Exception:
        try:
            conn.close()
        except Exception:
            pass
        _state["evt_conn"] = None


def _emit_event(now, mode, detail):
    _emit({"type": "event", "t": now, "mode": mode, "detail": detail})


def _apply_intent(message, now):
    """One intention from the voice character. Advisory by design -- see the module header."""
    kind = message.get("type")

    if kind == "stop":
        # The one imperative. A person saying "stop" means now, and it is also the safety path.
        mbot2.drive_speed(0, 0)
        _state["gesture"] = None
        _state["gesture_repeats"] = 0
        _state["level"] = 0.0
        _state["rpm"] = 0
        _state["drive_started"] = None
        _state["return_to"] = "listening"
        _enter("settling", now, "stopped by voice")  # via settling so the next read is clean
        return

    if kind == "mood":
        mood = message.get("mood")
        if mood in MOODS:
            _state["mood"] = mood
            _state["mood_since"] = now
            if mood == "still":
                _hold_still(now)
            _emit({"type": "ack", "t": now, "of": "mood", "id": str(message.get("id", "")), "mood": mood})
        return

    if kind == "gesture":
        gesture = message.get("gesture")
        if gesture in GESTURES:
            times = message.get("times", 1)
            try:
                times = max(1, min(MAX_GESTURE_REPEATS, int(times)))
            except Exception:
                times = 1
            # Waits for a seam where interrupting would not feel wrong. Repeats are counted down
            # one at a time rather than run as one long movement, so "stop" can land between them.
            _state["gesture"] = (gesture, utime.ticks_add(now, GESTURE_TTL_MS))
            _state["gesture_name"] = gesture
            _state["gesture_repeats"] = times - 1
            _state["gesture_id"] = str(message.get("id", ""))
            _emit(
                {
                    "type": "ack",
                    "t": now,
                    "of": "gesture",
                    "id": _state["gesture_id"],
                    "gesture": gesture,
                    "times": times,
                }
            )
        return


def _take_gesture(now):
    """Returns the next gesture to perform, counting down any repeats first."""
    """Consumes a queued gesture if one is still valid. Called only from listening, so reflexes
    (startle, bump, approach) always win and a gesture can never interrupt a flinch."""
    queued = _state["gesture"]
    if queued is None:
        if _state["gesture_repeats"] > 0:
            _state["gesture_repeats"] -= 1
            return _state["gesture_name"]
        return None
    name, expires = queued
    _state["gesture"] = None
    if utime.ticks_diff(expires, now) <= 0:
        _emit({"type": "event", "t": now, "mode": "listening", "detail": "gesture expired: " + name})
        return None
    return name


def _perform_gesture(gesture, now):
    """Both gestures reuse machinery the motion loop already has, rather than adding new states
    with their own untuned timings."""
    if gesture == "spin":
        _state["turn_ms"] = GESTURE_SPIN_MS  # a whole turn, not the tuned half-turn
        _state["turn_rpm"] = TURN_RPM
        _enter("turning", now, "gesture: spin")
        _show_face("O   O", (255, 150, 0))
        return
    if gesture == "wiggle":
        # The recovery wobble without its leading 180 -- a glance-about, not a full turn.
        _state["recover_index"] = 1
        _state["recover_seg_start"] = now
        _enter("recovering", now, "gesture: wiggle")


def _open_observer_sockets():
    """Best-effort, and retried -- see _pump_observers.

    A board that cannot open these still drives exactly as step16 does; it just cannot be watched
    or asked for anything. The retry matters because of how pushes work: bootstrap replaces the
    payload without the old one getting a chance to close its sockets, so immediately after an OTA
    push the previous instance may still hold this port and bind() is refused. Trying once at boot
    meant one push could leave the board permanently unwatchable until a power cycle."""
    try:
        import gc

        gc.collect()  # encourage the replaced payload's sockets to actually be released
    except Exception:
        pass
    try:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", EVENT_PORT))
        server.listen(1)
        server.settimeout(0)  # non-blocking accept -- this is a payload, not the owner of the loop
        _state["evt_server"] = server
    except Exception as error:
        _state["evt_server"] = None
        _report_error_once("event_server_failed", error)

    try:
        beacon = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        beacon.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        _state["evt_beacon"] = beacon
    except Exception as error:
        _state["evt_beacon"] = None
        _report_error_once("event_beacon_failed", error)


OBSERVER_RETRY_MS = 3000


def _pump_observers(now):
    if _state["evt_server"] is None:
        # Retry rather than give up for the life of the payload; the port is usually free again
        # within a few seconds of a push.
        if utime.ticks_diff(now, _state["evt_last_retry"]) >= OBSERVER_RETRY_MS:
            _state["evt_last_retry"] = now
            _open_observer_sockets()

    """One non-blocking step of beacon/accept/read per tick. Mirrors rocky_agent.py's proven
    pattern on this hardware rather than inventing another one."""
    try:
        beacon = _state["evt_beacon"]
        if beacon is not None and utime.ticks_diff(now, _state["evt_last_beacon"]) >= EVENT_BEACON_INTERVAL_MS:
            _state["evt_last_beacon"] = now
            # Carries no IP: the board cannot know its own (see rocky_agent.py). The receiver
            # reads the sender's address off the packet, which is the one address always correct.
            beacon.sendto(
                ujson.dumps({"service": EVENT_SERVICE, "tcpPort": EVENT_PORT}).encode(),
                ("255.255.255.255", EVENT_BEACON_PORT),
            )
    except Exception as error:
        # Surfaced, not swallowed. A silent except here is what made this look like "the phone
        # cannot find the robot" when the board was simply never sending -- and this project has
        # already learned that lesson once, on the bump sensor.
        _report_error_once("beacon_failed", error)

    server = _state["evt_server"]
    if server is None:
        return  # retried above

    # Always accept, even when a client is already held. A phone that goes away without closing
    # cleanly (killed by a redeploy, backgrounded, off Wi-Fi) leaves this socket looking alive for
    # as long as TCP keeps retransmitting -- and with listen(1) and no accept, the next connection
    # attempt is refused outright. That is what "no autonomous robot out there" meant on a board
    # that was sitting right there working: one dead client wedged the only slot. The newest
    # connection wins; there is only ever one phone.
    try:
        connection, _addr = server.accept()
    except Exception:
        connection = None
    if connection is not None:
        previous = _state["evt_conn"]
        if previous is not None:
            try:
                previous.close()
            except Exception:
                pass
        connection.settimeout(0)
        _state["evt_conn"] = connection
        _state["evt_buffer"] = ""
        # A client connecting mid-flee needs the backlog to make sense of what it is seeing.
        _emit({"type": "hello", "t": now, "mood": _state["mood"], "mode": _state["mode"]})
        for entry in _state["events"]:
            _emit({"type": "event", "t": entry[0], "mode": entry[1], "detail": entry[2]})
        return

    try:
        chunk = _state["evt_conn"].recv(256)
    except Exception:
        chunk = None
    if chunk:
        try:
            _state["evt_buffer"] += chunk.decode("utf-8")
            while "\n" in _state["evt_buffer"]:
                line, _state["evt_buffer"] = _state["evt_buffer"].split("\n", 1)
                if line.strip():
                    _apply_intent(ujson.loads(line), now)
        except Exception as error:
            _report_error_once("intent_error", error)
            _state["evt_buffer"] = ""

    if utime.ticks_diff(now, _state["evt_last_snapshot"]) >= SNAPSHOT_INTERVAL_MS:
        _state["evt_last_snapshot"] = now
        _emit(
            {
                "type": "snapshot",
                "t": now,
                "mode": _state["mode"],
                "rpm": _state["rpm"],
                "mood": _state["mood"],
                "since_ms": utime.ticks_diff(now, _state["mode_start"]),
            }
        )


def _interp(table, x):
    if x <= table[0][0]:
        return table[0][1]
    for index in range(1, len(table)):
        x0, y0 = table[index - 1]
        x1, y1 = table[index]
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return table[-1][1]


def _connect_telemetry():
    _state["sock_tried"] = True
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((LAPTOP_HOST, LAPTOP_PORT))
        sock.settimeout(2)
        _state["sock"] = sock
    except Exception:
        _state["sock"] = None  # driving must work with no laptop listening


def _send_telemetry(extra):
    if _state["sock"] is None:
        return
    try:
        _state["sock"].sendall(
            '{{"t":{},"phase":"live","mode":"{}","level":{},"rpm":{}{}}}\n'.format(
                utime.ticks_ms(), _state["mode"], round(_state["level"], 3), _state["rpm"], extra
            ).encode()
        )
    except Exception:
        try:
            _state["sock"].close()
        except Exception:
            pass
        _state["sock"] = None


def _report_error_once(event, error):
    """Surface a swallowed exception via telemetry, once per event key -- a silent `except:
    return None` looks identical whether the hardware isn't there or the call is just wrong,
    and that ambiguity is exactly what made the bump feature undebuggable live."""
    if event in _state["reported_errors"]:
        return
    _state["reported_errors"].append(event)
    _send_telemetry(',"event":"{}","error":"{}"'.format(event, str(error).replace('"', "'")))


def _show_face(label, color):
    cyberpi.display.clear()
    cyberpi.display.show_label(label, 32, 30, 50, 0)
    cyberpi.led.on(color[0], color[1], color[2], id="all")


def _face_for_level(level):
    face = FACES[0]
    for candidate in FACES:
        if level >= candidate[0]:
            face = candidate
    return face


def _enter(mode, now, detail=""):
    if mode == "listening":
        # The robot has just moved, so the previous per-channel baseline describes a patch of
        # floor it is no longer over. Re-seed on the next tick rather than easing toward the new
        # reading, which is what let a single spin cascade into an endless one.
        _state["reflect_baseline"] = [None, None, None, None]
    _state["mode"] = mode
    _state["mode_start"] = now
    # The one choke point every transition already passes through, which is why observation hooks
    # here rather than into each state: no tick() path gains work, and no transition can be
    # forgotten later.
    events = _state["events"]
    events.append((now, mode, detail))
    if len(events) > EVENT_HISTORY:
        events.pop(0)
    _emit_event(now, mode, detail)


def _ext_repr(external):
    """JSON-safe representation of an optional external reading (see _sensed_level)."""
    return "null" if external is None else round(external, 1)


def _random_sign():
    """+1 or -1, picked from the low bit of the current tick count. No confirmed `random`
    module in this project's typings (typings/ has no random.pyi, and nothing else here
    imports it) -- rather than risk an unconfirmed import failing to upload, this reuses timing
    jitter that's already unpredictable enough for "which way to turn when startled by an
    obstacle," which doesn't need real randomness."""
    return 1 if utime.ticks_ms() % 2 == 0 else -1


def _sensed_level(rpm_magnitude):
    """Self-noise-subtracted CURVE level given some known RPM magnitude currently commanded --
    lets any motors-on state notice a genuinely louder sound and react (see module header).

    Returns (None, loudness, None) when rpm_magnitude exceeds SELF_NOISE's calibrated range
    (60). _interp would otherwise silently clamp to the 60 RPM self-noise value (83) for any
    higher RPM, badly UNDER-estimating real self-noise up there -- and TURN_RPM/JUMP_RPM/FLEE_RPM
    and driving's own committed rpm now regularly exceed 60 since MAX_RPM was raised to 150. That
    under-estimate was mistaking the robot's own motor noise for a real surprise at every one of
    these higher speeds, reintroducing the original v3 feedback-loop bug -- a real regression
    caught live (2026-08-08): a "yellow (turning/recovering) <-> blue (listening) spin loop" with
    no sound involved at all. Refusing to guess beyond measured data is safer than a bad guess.
    """
    loudness = cyberpi.get_loudness()
    if rpm_magnitude > SELF_NOISE[-1][0]:
        return None, loudness, None
    self_noise = _interp(SELF_NOISE, rpm_magnitude)
    external = max(0.0, loudness - _state["floor"] - self_noise)
    return _interp(CURVE, external), loudness, external


def _start_driving(level, now):
    _state["level"] = level
    _state["rpm"] = max(MIN_RPM, int(level * MAX_RPM * _mood()["speed"]))
    _state["sustain_ms"] = int(SUSTAIN_MIN_MS + level * (SUSTAIN_MAX_MS - SUSTAIN_MIN_MS))
    if _state["drive_started"] is None:
        _state["drive_started"] = now
    _enter("driving", now)
    mbot2.drive_speed(_state["rpm"], -_state["rpm"])
    _show_face(*_face_for_level(level)[2:])


def _boot():
    mbot2.drive_speed(0, 0)  # guarantee motors are physically stopped before seeding the floor,
    # in case a mid-drive payload was just replaced by this push
    utime.sleep_ms(SETTLE_MS)
    samples = []
    for _ in range(FLOOR_SEED_SAMPLES):
        samples.append(cyberpi.get_loudness())
        utime.sleep_ms(FLOOR_SEED_INTERVAL_MS)
    _state["floor"] = min(samples)
    _state["booted"] = True
    _connect_telemetry()
    _open_observer_sockets()
    # One-time capability report -- "did it even import" was invisible before, and a bump never
    # firing could equally mean "no sensor" or "wrong threshold." No point guessing which.
    _send_telemetry(
        ',"event":"sensors","has_ultrasonic":{},"has_line_sensor":{}'.format(
            "true" if HAS_ULTRASONIC else "false", "true" if HAS_LINE_SENSOR else "false"
        )
    )
    _enter("listening", utime.ticks_ms())
    _show_face("o _ o", (0, 150, 255))


def _tick_listening(now):
    loudness = cyberpi.get_loudness()  # motors are off in this mode -- a clean read, no self
    external = max(0.0, loudness - _state["floor"])  # noise term needed at all
    _state["baseline"] += BASELINE_ALPHA * (external - _state["baseline"])

    startled = external >= STARTLE_CUTOFF * _mood()["startle"]
    startled = startled and (external - _state["baseline"]) >= STARTLE_JUMP_THRESHOLD
    if startled:
        # Surprise magnitude, 0 at the startle threshold to 1 at the sensor's observed ceiling
        # (real calibration readings topped out at 100) -- scales how far the flee goes.
        headroom = SENSOR_MAX - STARTLE_CUTOFF
        surprise = min(1.0, max(0.0, (external - STARTLE_CUTOFF) / headroom))
        _state["flee_ms"] = int(FLEE_MS_MIN + surprise * (FLEE_MS_MAX - FLEE_MS_MIN))
        # The reason travels with the transition. "startled" alone cannot be turned into anything
        # a person would say -- being frightened by a shout and being crowded by something moving
        # in are different experiences, and the observer has no other way to tell them apart.
        _enter("startled", now, "loud noise")
        _show_face("O   O", (255, 255, 255))
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, round(external, 1)))
        return

    # Raw sensor values, always included below (not just when something fires) -- a bump never
    # triggering could mean "no sensor," "wrong threshold," or "working fine, nothing touched it,"
    # and those look identical without visibility into the actual numbers.
    readings = _reflect_readings()
    reflect_extra = ',"reflect":null,"reflect_baseline":null'
    bumped = False
    if readings is not None:
        for i, reading in enumerate(readings):
            baseline = _state["reflect_baseline"][i]
            if baseline is None:
                _state["reflect_baseline"][i] = reading
            else:
                if abs(reading - baseline) > BUMP_THRESHOLD:
                    bumped = True
                _state["reflect_baseline"][i] += REFLECT_BASELINE_ALPHA * (reading - baseline)
        reflect_extra = ',"reflect":[{}],"reflect_baseline":[{}]'.format(
            ",".join(str(r) for r in readings),
            ",".join(str(b) for b in _state["reflect_baseline"]),
        )
    if bumped and utime.ticks_diff(now, _state["bump_suppressed_until"]) < 0:
        bumped = False  # cooling down after spinning twice; still listening for everything else

    if bumped:
        if utime.ticks_diff(now, _state["dizzy_last_at"]) > DIZZY_STREAK_RESET_MS:
            _state["dizzy_streak"] = 0
        _state["dizzy_streak"] += 1
        _state["dizzy_last_at"] = now
        detail = "bump"
        if _state["dizzy_streak"] >= DIZZY_MAX_CONSECUTIVE:
            # Let this second one happen, then stop being ticklish for a while.
            _state["bump_suppressed_until"] = utime.ticks_add(now, DIZZY_COOLDOWN_MS)
            _state["dizzy_streak"] = 0
            detail = "bump (cooling down after two)"
        _enter("dizzy", now, detail)
        _show_face(*DIZZY_FACE)
        _send_telemetry(',"bump":true' + reflect_extra)
        return

    distance_extra = ',"distance_cm":null'
    if HAS_ULTRASONIC:
        distance = _distance_cm()
        distance_extra = ',"distance_cm":{}'.format(distance)
        close_now = 0 <= distance < APPROACH_CM
        if close_now and not _state["was_close"]:
            surprise = 1.0 - (distance / APPROACH_CM)  # closer -> more startled, see STARTLE_CUTOFF
            _state["flee_ms"] = int(FLEE_MS_MIN + surprise * (FLEE_MS_MAX - FLEE_MS_MIN))
            _state["was_close"] = close_now
            _enter("startled", now, "came close")
            _show_face("O   O", (255, 255, 255))
            _send_telemetry(',"approach_cm":{}'.format(distance) + reflect_extra)
            return
        _state["was_close"] = close_now

    gesture = _take_gesture(now)
    if gesture is not None:
        # Consumed here and nowhere else: reflexes above have already had their chance, so an
        # intention can never interrupt a flinch, a bump or an obstacle reaction.
        _perform_gesture(gesture, now)
        return

    level = _interp(CURVE, external)
    if level > MIN_LEVEL and _mood()["speed"] > 0:
        _start_driving(level, now)

    _send_telemetry(
        ',"loud":{},"external":{}'.format(loudness, round(external, 1)) + reflect_extra
        + distance_extra
    )


def _tick_driving(now):
    distance = _distance_cm()
    if HAS_ULTRASONIC and 0 <= distance < OBSTACLE_STOP_CM:
        mbot2.drive_speed(0, 0)
        # Shorter, randomly-directioned turn than the personality 8s-timeout one below -- see
        # OBSTACLE_TURN_MS's comment. Random because there's no way to tell which side is more
        # open with a single fixed forward-facing sensor; always turning the same way would mean
        # always turning toward whatever's usually on that side.
        _state["turn_ms"] = OBSTACLE_TURN_MS
        _state["turn_rpm"] = TURN_RPM * _random_sign()
        _state["return_to"] = "turning"
        _state["turn_reason"] = "obstacle"
        _enter("settling", now)
        _send_telemetry(',"obstacle_cm":{}'.format(distance))
        return

    if utime.ticks_diff(now, _state["drive_started"]) >= DRIVE_TIMEOUT_MS:
        mbot2.drive_speed(0, 0)
        _state["turn_ms"] = TURN_MS
        _state["turn_rpm"] = TURN_RPM
        _state["return_to"] = "turning"
        _state["turn_reason"] = "been going a while"
        _enter("settling", now)
        return

    candidate_level, loudness, external = _sensed_level(_state["rpm"])
    if candidate_level is not None and candidate_level > _state["level"]:  # louder -- escalate
        _start_driving(candidate_level, now)  # refreshes mode_start, so the sustain check below
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, _ext_repr(external)))
        return
    # A quieter-or-equal reading (or an untrusted one -- see _sensed_level) is ignored on purpose:
    # the commitment holds steady rather than decaying or jittering with every tick's noise.

    if utime.ticks_diff(now, _state["mode_start"]) >= _state["sustain_ms"]:
        mbot2.drive_speed(0, 0)
        _state["return_to"] = "listening"
        _state["drive_started"] = None
        _enter("settling", now)
        return
    mbot2.drive_speed(_state["rpm"], -_state["rpm"])
    _send_telemetry(',"loud":{},"external":{}'.format(loudness, _ext_repr(external)))


def _tick_settling(now):
    if utime.ticks_diff(now, _state["mode_start"]) < SETTLE_MS:
        _send_telemetry("")
        return
    if _state["return_to"] == "turning":
        _enter("turning", now, _state["turn_reason"])
        _show_face("O   O", (255, 150, 0))
    else:
        _state["level"] = 0.0
        _state["rpm"] = 0
        _enter("listening", now)
        _show_face("o _ o", (0, 150, 255))


def _tick_turning(now):
    level, loudness, external = _sensed_level(abs(_state["turn_rpm"]))
    if level is not None and level > MIN_LEVEL:  # a surprise mid-turn takes priority
        _start_driving(level, now)
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, _ext_repr(external)))
        return

    elapsed = utime.ticks_diff(now, _state["mode_start"])
    if elapsed < _state["turn_ms"]:
        mbot2.drive_speed(_state["turn_rpm"], _state["turn_rpm"])  # spin in place
        _send_telemetry("")
    else:
        mbot2.drive_speed(0, 0)
        _state["drive_started"] = None
        _state["return_to"] = "listening"
        _enter("settling", now)


def _tick_startled(now):
    elapsed = utime.ticks_diff(now, _state["mode_start"])
    jumping = elapsed < JUMP_MS
    level, loudness, external = _sensed_level(JUMP_RPM if jumping else FLEE_RPM)
    if level is not None and level > MIN_LEVEL:  # a surprise mid-flee takes priority
        _start_driving(level, now)
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, _ext_repr(external)))
        return

    if jumping:
        mbot2.drive_speed(-JUMP_RPM, JUMP_RPM)  # sharp reverse jolt -- the closest analog to a
        # "jump" the mBot2 has, given it has no legs
        _send_telemetry("")
    elif elapsed < JUMP_MS + _state["flee_ms"]:
        mbot2.drive_speed(-FLEE_RPM, FLEE_RPM)  # keep retreating, at a fixed speed for the whole
        _send_telemetry("")  # duration -- "without slowing down" -- only the duration scales
    else:
        _state["baseline"] = 0.0
        _enter_recovering(now)


def _enter_recovering(now):
    _state["recover_index"] = 0
    _state["recover_seg_start"] = now
    _enter("recovering", now)
    _, _, label, color = RECOVER_SCHEDULE[0]
    _show_face(label, color)


def _tick_recovering(now):
    idx = _state["recover_index"]
    duration, rpm, _, _ = RECOVER_SCHEDULE[idx]

    level, loudness, external = _sensed_level(abs(rpm))
    if level is not None and level > MIN_LEVEL:  # a surprise mid-wobble takes priority
        _start_driving(level, now)
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, _ext_repr(external)))
        return

    if utime.ticks_diff(now, _state["recover_seg_start"]) >= duration:
        idx += 1
        if idx >= len(RECOVER_SCHEDULE):
            mbot2.drive_speed(0, 0)
            _state["return_to"] = "listening"
            _enter("settling", now)
            return
        _state["recover_index"] = idx
        _state["recover_seg_start"] = now
        duration, rpm, label, color = RECOVER_SCHEDULE[idx]
        _show_face(label, color)
    mbot2.drive_speed(rpm, rpm)  # spin in place -- sign picks direction, see RECOVER_SCHEDULE
    _send_telemetry("")


def _tick_dizzy(now):
    level, loudness, external = _sensed_level(DIZZY_RPM)
    if level is not None and level > MIN_LEVEL:  # a surprise mid-spin takes priority
        _start_driving(level, now)
        _send_telemetry(',"loud":{},"external":{}'.format(loudness, _ext_repr(external)))
        return

    if utime.ticks_diff(now, _state["mode_start"]) >= DIZZY_MS:
        mbot2.drive_speed(0, 0)
        _state["return_to"] = "listening"
        _enter("settling", now)
        return
    mbot2.drive_speed(DIZZY_RPM, DIZZY_RPM)  # spin in place, sustained -- see DIZZY_MS
    _send_telemetry("")


_TICKS = {
    "listening": _tick_listening,
    "driving": _tick_driving,
    "settling": _tick_settling,
    "turning": _tick_turning,
    "startled": _tick_startled,
    "recovering": _tick_recovering,
    "dizzy": _tick_dizzy,
}


def tick():
    if not _state["booted"]:
        _boot()
        return

    now = utime.ticks_ms()
    try:
        _pump_observers(now)
        _decay_mood(now)
        if _state["mood"] == "still":
            _hold_still(now)
        else:
            _TICKS[_state["mode"]](now)
    except Exception:
        mbot2.drive_speed(0, 0)  # never let bootstrap drop this payload with motors spinning
        raise
